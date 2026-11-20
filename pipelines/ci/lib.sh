#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  lib.sh — sourced by EVERY ci script (never executed on its own)
#  Gives each script: repo paths, the build's scratch dirs, logging, tool checks,
#  the apply-order reader, the account-alias renderer and the working-copy builder.
#  Written for bash 3.2+ (macOS) as well as bash 5 (Linux agents): no mapfile, no associative arrays.
# ════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── where things are (derived from THIS file, so spaces / any checkout path are fine) ──
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_DIR="$ROOT/pipelines/ci"
LIVE="$ROOT/infra-live"
MODS="$ROOT/infra-modules"
POLICY_DIR="$ROOT/policy"
STATE_DIR="${CI_STATE_DIR:-$ROOT/.ci}"     # per-build scratch: stack lists, summaries, temp credentials (gitignored)
WORK="${CI_WORK_DIR:-$ROOT/.work}"         # per-stack working copies: where init / plan / apply really run (gitignored)
mkdir -p "$STATE_DIR" "$WORK"

# ── build parameters (the Jenkinsfile's "Checkout" stage normalises them into TARGET_*) ──
ORG="${ORG:-acme}"
TARGET_ENV="${TARGET_ENV:-${ENV:-any}}"             # dev | qa | stage | stage-dr | prod | _shared | org | tooling | any
TARGET_REGION="${TARGET_REGION:-${REGION:-any}}"    # eu-west-1 | _ (region-less org leaves) | any
TARGET_ACTION="${TARGET_ACTION:-${ACTION:-plan}}"   # plan | apply
COMPONENT="${COMPONENT:-all}"                       # one stack folder, or "all"
PLAN_PARALLEL="${PLAN_PARALLEL:-4}"                 # cap: provider APIs throttle if every stack plans at once
CHANGED_FILE="$STATE_DIR/changed_stacks.txt"        # written by detect_changed_stacks.sh, read by everything after it
APPLY_FILE="$STATE_DIR/apply_stacks.txt"            # stacks whose plan actually has changes (written by plan_all.sh)

# ── tiny helpers ──
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { log "WARN: $*"; }
die()  { log "ERROR: $*"; exit 1; }
need() { local b; for b in "$@"; do command -v "$b" >/dev/null 2>&1 || die "required tool missing on the agent: $b"; done; }

# stack id: a path "L5-edge-app/dev/eu-west-1/acm" becomes a folder-safe name for .work/ and for result files
stack_id() { printf '%s' "$1" | sed 's|/|__|g'; }

# ── layer → the pipeline's order file(s) ──
layer_orders() {
  case "$1" in
    L0-bootstrap)         echo "bootstrap" ;;
    L1-global-governance) echo "global" ;;
    L2-network)           echo "network" ;;
    L3-platform-data)     echo "platform" ;;
    L4-cluster-addons)    echo "addons" ;;
    L5-edge-app)          echo "edge edge-dns" ;;
    *) die "unknown layer folder: $1" ;;
  esac
}

# order_table <order-name> → lines "<rank>\t<component>".  Same rank = same parallel group ("a | b | c" on one line).
order_table() {
  awk '{ sub(/#.*/, "") } /^[[:space:]]*$/ { next }
       { r++; n = split($0, a, "|");
         for (i = 1; i <= n; i++) { gsub(/[[:space:]]/, "", a[i]); if (a[i] != "") print r "\t" a[i] } }' \
    "$CI_DIR/order/$1.order"
}

# order_of_stack <order-name> <stack> → the stack's rank in that order file, empty if the component is not listed there
order_of_stack() {
  local comp; comp="$(basename "$2")"
  order_table "$1" | awk -F'\t' -v c="$comp" '$2 == c { print $1; exit }'
}

# ── account aliases: git only ever holds DEV_ACCOUNT, PROD_ACCOUNT … ; the real ids come from a CI secret file ──
# ACCOUNT_MAP_FILE (Jenkins "secret file" credential) has lines like  DEV_ACCOUNT=<12 digits>
ALIASES="MGMT_ACCOUNT SECURITY_ACCOUNT LOGARCHIVE_ACCOUNT TOOLING_ACCOUNT NETWORK_ACCOUNT SHARED_ACCOUNT DEV_ACCOUNT QA_ACCOUNT STAGE_ACCOUNT PROD_ACCOUNT EMEA_ACCOUNT"

account_id() {   # account_id DEV_ACCOUNT → 12-digit id from the secret map
  [ -n "${ACCOUNT_MAP_FILE:-}" ] && [ -f "$ACCOUNT_MAP_FILE" ] || die "ACCOUNT_MAP_FILE not set — the real account ids live only in the CI secret store"
  local v; v="$(grep -E "^$1=" "$ACCOUNT_MAP_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]"')"
  [ -n "$v" ] || die "no id for $1 in the account map"
  printf '%s' "$v"
}

# render_aliases <dir> real|dummy
#   real  : replace every ALIAS with the real id            (plan / apply — needs ACCOUNT_MAP_FILE)
#   dummy : replace with obviously-fake sequential ids       (validate / lint / scan — no secrets needed, but ARNs stay well-formed)
#   Edits only the temp working copy, never the git checkout; skips .terraform/providers (binaries).
render_aliases() {
  local dir="$1" mode="$2" a id i=0 sedargs=()
  for a in $ALIASES; do
    i=$((i + 1))
    if [ "$mode" = real ]; then id="$(account_id "$a")"; else id="$(printf '9%011d' "$i")"; fi   # dummy: "9" + 11 digits = a fake but well-formed 12-digit id (and no 12-digit literal in git)
    sedargs+=(-e "s/$a/$id/g")   # plain substring is safe: no alias is part of another alias or a longer word
  done
  find "$dir" -type f \( -name '*.tf' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.tpl' -o -name '*.sh' -o -name '*.py' \) \
       -not -path '*/.terraform/providers/*' -not -name 'tfplan.json' -print0 \
    | xargs -0 sed -i.bak "${sedargs[@]}"
  find "$dir" -name '*.bak' -type f -delete
}

# ── make Terraform able to fetch the modules repo over https with a token (never written into the repo or the plan) ──
git_auth() {
  [ -n "${MODULES_REPO_TOKEN:-}" ] || return 0
  export GIT_CONFIG_GLOBAL="$STATE_DIR/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" url."https://x-access-token:${MODULES_REPO_TOKEN}@git.example.com/".insteadOf "https://git.example.com/"
  chmod 600 "$GIT_CONFIG_GLOBAL"
}

# ── secrets the leaves declare as `variable … sensitive = true` (TF_VAR_*), supplied as ONE secret file ──
load_tf_secrets() {
  if [ -n "${TF_SECRETS_FILE:-}" ] && [ -f "$TF_SECRETS_FILE" ]; then
    set -a; . "$TF_SECRETS_FILE"; set +a
  fi
}

# ── terraform init flags (an ARRAY, so a path with spaces survives): offline provider mirror for air-gapped agents / local tests ──
TF_INIT_ARGS=(-input=false -no-color)
if [ -n "${TF_PLUGIN_DIR:-}" ]; then TF_INIT_ARGS+=("-plugin-dir=$TF_PLUGIN_DIR"); fi

# ── build ONE working copy for a stack ──
#   make_workdir <stack> [live-root] [modules-root] [dest-dir]      prints the working-copy path
#   - copies infra-live/<stack> to <dest>/<id>
#   - rewrites the leaves' FLOATING module source  git::…//<layer>/<module>?ref=main  to the LOCAL checkout (relative path),
#     so a PR plans the module code that is in THIS commit and dev's apply is reproducible from the commit.
#     Tagged refs (v1.3.2, v1.4.0-rc.1) are left alone: qa/stage/prod always build from the immutable tag.
#     LOCAL_MODULES_ALL=true rewrites tagged refs too (air-gapped agents, local tests).
#   - Terraform only accepts local module paths that start with ./ or ../, hence the relative prefix.
make_workdir() {
  local stack="$1" live="${2:-$LIVE}" mods="${3:-$MODS}" dest="${4:-$WORK}" wd refpat='main' rel prefix
  [ "${LOCAL_MODULES_ALL:-false}" = true ] && refpat='[A-Za-z0-9._-]+'
  wd="$dest/$(stack_id "$stack")"
  rm -rf "$wd"; mkdir -p "$wd"
  cp -R "$live/$stack/." "$wd/"
  rel="${wd#$ROOT/}"; prefix="$(printf '%s' "$rel" | awk -F/ '{ s = ""; for (i = 1; i <= NF; i++) s = s "../"; print s }')"
  find "$wd" -name '*.tf' -print0 | xargs -0 sed -i.bak -E \
    "s#git::https://git\.example\.com/infra-modules\.git//([A-Za-z0-9_./-]+)\?ref=$refpat#${prefix}${mods#$ROOT/}/\1#g"
  find "$wd" -name '*.bak' -type f -delete
  printf '%s' "$wd"
}

# ── credentials ──
# load_aws: the ci-bootstrap session written by assume_role.sh (OIDC → ci-bootstrap in TOOLING). The AWS PROVIDER does the second hop
# (→ terraform-exec in the leaf's own account, with the ExternalId), so plan/apply need nothing more than this.
load_aws() {
  [ -f "$STATE_DIR/aws.env" ] || die "no AWS session — the Authenticate stage (assume_role.sh) must run first"
  . "$STATE_DIR/aws.env"
  export TF_IN_AUTOMATION=1 TF_INPUT=0
}
# exec_env <stack> → prints `export AWS_…` lines for terraform-exec in THAT stack's account (for the CLI smoke tests / helm diff).
# The account is read from the leaf's own provider block, so there is one source of truth.
exec_env() {
  local alias_ acct creds
  alias_="$(grep -hoE 'arn:aws:iam::[A-Z_]+:role/terraform-exec' "$LIVE/$1/main.tf" | head -1 | sed -E 's#arn:aws:iam::([A-Z_]+):.*#\1#')"
  [ -n "$alias_" ] || die "no terraform-exec role in $1/main.tf"
  acct="$(account_id "$alias_")"
  creds="$(aws sts assume-role --role-arn "arn:aws:iam::$acct:role/terraform-exec" --role-session-name "${CI_SESSION_NAME:-ci-verify}" \
           --external-id "${TF_VAR_external_id:?TF_VAR_external_id not set}" --duration-seconds 900 --output json)"
  printf 'export AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s\n' \
    "$(printf '%s' "$creds" | jq -r .Credentials.AccessKeyId)" "$(printf '%s' "$creds" | jq -r .Credentials.SecretAccessKey)" "$(printf '%s' "$creds" | jq -r .Credentials.SessionToken)"
}

# leaf_ref <stack> → the ?ref= the leaf pins (main | v1.x | none)
leaf_ref() { grep -hoE '\?ref=[A-Za-z0-9._-]+' "$LIVE/$1/main.tf" | head -1 | sed 's/?ref=//' || true; }
