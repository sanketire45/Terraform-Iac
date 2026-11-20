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

# ── config files (Whirlpool style): pipelines/config/<scope>-config.txt, one KEY=value per line ──
# Whirlpool:  config_file = "config/${ENV_STAGE}-config.txt"   +   gvInfra.readConfigParameter("AWS_ACCOUNT_ID", config_file)
# Here     :  config_file dev   →  .../pipelines/config/dev-config.txt   +   read_config AWS_ACCOUNT_ID "$(config_file dev)"
CONFIG_DIR="$ROOT/pipelines/config"
config_file() { printf '%s/%s-config.txt' "$CONFIG_DIR" "$1"; }          # config_file <scope>   scope = dev | qa | stage | prod | _shared
read_config() {                                                           # read_config KEY FILE  → the text after "KEY="
  [ -f "$2" ] || die "config file not found: ${2#$ROOT/}"
  grep -E "^$1=" "$2" | head -1 | cut -d= -f2- | tr -d '[:space:]"' || true
}
stack_scope() { printf '%s' "$1" | cut -d/ -f2; }                        # L3-platform-data/dev/eu-west-1/kms → dev

# ── account aliases: git only ever holds DEV_ACCOUNT, PROD_ACCOUNT … ; the real ids come from the config files ──
ALIASES="MGMT_ACCOUNT SECURITY_ACCOUNT LOGARCHIVE_ACCOUNT TOOLING_ACCOUNT NETWORK_ACCOUNT SHARED_ACCOUNT DEV_ACCOUNT QA_ACCOUNT STAGE_ACCOUNT PROD_ACCOUNT EMEA_ACCOUNT"

account_id() {   # account_id DEV_ACCOUNT → the 12-digit id, read from the matching config file
  local scope key v
  case "$1" in
    DEV_ACCOUNT)     scope=dev;     key=AWS_ACCOUNT_ID ;;
    QA_ACCOUNT)      scope=qa;      key=AWS_ACCOUNT_ID ;;
    STAGE_ACCOUNT)   scope=stage;   key=AWS_ACCOUNT_ID ;;
    PROD_ACCOUNT)    scope=prod;    key=AWS_ACCOUNT_ID ;;
    SHARED_ACCOUNT)  scope=_shared; key=AWS_ACCOUNT_ID ;;
    TOOLING_ACCOUNT) scope=_shared; key=SHARED_ACCOUNT_ID ;;    # the account that holds the state bucket
    *) die "alias $1 has no config entry in this copy (add a case to account_id in lib.sh)" ;;
  esac
  if [ "$key" = AWS_ACCOUNT_ID ] && [ "$scope" = "${TARGET_ENV:-}" ] && [ -n "${AWS_ACCOUNT_ID:-}" ]; then
    v="$AWS_ACCOUNT_ID"
  elif [ "$key" = SHARED_ACCOUNT_ID ] && [ -n "${SHARED_ACCOUNT_ID:-}" ]; then
    v="$SHARED_ACCOUNT_ID"
  else
    v="$(read_config "$key" "$(config_file "$scope")")"
  fi
  case "$v" in ''|REPLACE*) die "$key is not filled in: ${scope}-config.txt" ;; esac
  printf '%s' "$v"
}

# render_aliases <dir> real|dummy
#   real  : replace every ALIAS with the real id            (plan / apply — ids come from pipelines/config/*-config.txt)
#   dummy : replace with obviously-fake sequential ids       (validate / lint / scan — no secrets needed, but ARNs stay well-formed)
#   Edits only the temp working copy, never the git checkout; skips .terraform/providers (binaries).
render_aliases() {
  local dir="$1" mode="$2" a id i=0 sedargs=() left=""
  for a in $ALIASES; do
    i=$((i + 1))
    if [ "$mode" = real ]; then id="$(account_id "$a" 2>/dev/null)" || { left="$left $a"; continue; }; else id="$(printf '9%011d' "$i")"; fi   # dummy: "9" + 11 digits = a fake but well-formed 12-digit id (and no 12-digit literal in git)
    sedargs+=(-e "s/$a/$id/g")   # plain substring is safe: no alias is part of another alias or a longer word
  done
  find "$dir" -type f \( -name '*.tf' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.tpl' -o -name '*.sh' -o -name '*.py' \) \
       -not -path '*/.terraform/providers/*' -not -name 'tfplan.json' -print0 \
    | xargs -0 sed -i.bak "${sedargs[@]}"
  find "$dir" -name '*.bak' -type f -delete
  # an alias that no config file can resolve and that a leaf really uses = a clear error here, not a cryptic AWS error later
  for a in $left; do
    if grep -rqE --include='*.tf' "$a" "$dir" 2>/dev/null; then account_id "$a" >/dev/null; fi
  done
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
# assume_role.sh (Stage 7) writes ONE file per scope:  .ci/aws-dev.env , .ci/aws-prod.env …  (Whirlpool writes one profile instead).
# load_aws <stack> : load the session of THAT stack's scope into this shell → terraform / aws then act in that account.
load_aws() {
  local scope f; scope="$(stack_scope "${1:?load_aws needs a stack path}")"; f="$STATE_DIR/aws-$scope.env"
  [ -f "$f" ] || die "no AWS session for scope '$scope' — the Authenticate stage (assume_role.sh) must run first"
  unset AWS_PROFILE
  . "$f"
  export TF_IN_AUTOMATION=1 TF_INPUT=0
}
# exec_env <stack> → prints the `export AWS_…` lines of that stack's scope (for the CLI smoke tests / kubectl / helm diff): eval "$(exec_env "$s")"
exec_env() {
  local f; f="$STATE_DIR/aws-$(stack_scope "$1").env"
  [ -f "$f" ] || die "no AWS session for scope '$(stack_scope "$1")' — run the Authenticate stage first"
  cat "$f"
}

# leaf_ref <stack> → the ?ref= the leaf pins (main | v1.x | none)
leaf_ref() { grep -hoE '\?ref=[A-Za-z0-9._-]+' "$LIVE/$1/main.tf" | head -1 | sed 's/?ref=//' || true; }
