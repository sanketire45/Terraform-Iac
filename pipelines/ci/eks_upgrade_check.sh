#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  Cluster gate — pipeline-platform only (runs BEFORE approval/apply)
#  An EKS control-plane upgrade is one-way and one MINOR VERSION at a time. This script looks at the saved plan of every
#  `eks-cluster` leaf and:
#    • fails if the plan changes the Kubernetes version by more than +1 minor, or downgrades it;
#    • for a real upgrade, asks EKS "upgrade insights" whether anything blocks it (deprecated APIs in use, add-on versions) and fails on ERROR;
#    • runs kubent (deprecated-API finder) when it is installed.
#  Reads : .work/<id>/tfplan.json          Env: SKIP_CLUSTER_GATE=true to bypass knowingly (e.g. first creation has nothing to check)
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -s "$CHANGED_FILE" ] || { log "nothing to check"; exit 0; }
need jq
[ "${SKIP_CLUSTER_GATE:-false}" != true ] || { warn "SKIP_CLUSTER_GATE=true — cluster gate bypassed"; exit 0; }

checked=0
grep -E '/eks-cluster$' "$CHANGED_FILE" | while IFS= read -r s; do
  f="$WORK/$(stack_id "$s")/tfplan.json"; [ -f "$f" ] || die "no plan json for $s — run the plan stage first"
  before="$(jq -r '[.resource_changes[]? | select(.type == "aws_eks_cluster") | select(.change.actions | index("update")) | .change.before.version][0] // empty' "$f")"
  after="$( jq -r '[.resource_changes[]? | select(.type == "aws_eks_cluster") | select(.change.actions | index("update")) | .change.after.version ][0] // empty' "$f")"
  if [ -z "$before" ] || [ "$before" = "$after" ]; then log "$s: Kubernetes version unchanged (${before:-new cluster}) — nothing to gate"; continue; fi

  bmaj="${before%%.*}"; bmin="${before#*.}"; amaj="${after%%.*}"; amin="${after#*.}"
  [ "$bmaj" = "$amaj" ] || die "$s: major version change $before → $after is not supported by this pipeline"
  step=$((amin - bmin))
  [ "$step" -ge 0 ] || die "$s: $before → $after is a DOWNGRADE — EKS control planes cannot be downgraded"
  [ "$step" -le 1 ] || die "$s: $before → $after skips a minor version — EKS upgrades one minor at a time ($before → $bmaj.$((bmin + 1)) first)"
  log "$s: upgrade $before → $after (one minor) — asking EKS for upgrade insights"

  env_="$(printf '%s' "$s" | cut -d/ -f2)"; region="$(printf '%s' "$s" | cut -d/ -f3)"
  need aws; load_aws; load_tf_secrets
  out="$( ( eval "$(exec_env "$s")"
            aws eks list-insights --cluster-name "$env_-eks" --region "$region" --filter categories=UPGRADE_READINESS \
                --query 'insights[?insightStatus.status != `PASSING`].[name,insightStatus.status]' --output text ) )" \
    || die "$s: could not read EKS upgrade insights"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | sed 's/^/    insight: /' >&2
    printf '%s\n' "$out" | grep -qE '[[:space:]]ERROR$' && die "$s: EKS reports ERROR-level upgrade blockers (deprecated APIs in use / incompatible add-ons) — fix them first"
    warn "$s: EKS reports WARNING-level upgrade insights (see above)"
  else log "$s: no upgrade-readiness findings"; fi

  if command -v kubent >/dev/null 2>&1; then
    log "$s: kubent — APIs removed in $after"
    ( eval "$(exec_env "$s")"; export KUBECONFIG="$STATE_DIR/kubeconfig"
      aws eks update-kubeconfig --name "$env_-eks" --region "$region" --kubeconfig "$KUBECONFIG" >/dev/null
      kubent --target-version "$after.0" --exit-error ) || die "$s: kubent found workloads using APIs removed in $after"
  else warn "kubent is not installed on this agent — only the EKS insights were checked"; fi
done
log "cluster gate OK"

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   plan JSON, before/after          the saved plan says `version: "1.30" → "1.31"` for aws_eks_cluster; comparing the two numbers is a pure
#                                    text check, so it works with no AWS call and runs in milliseconds.
#   ${before%%.*} / ${before#*.}     shell parameter expansion: %%.* strips from the first dot to the end (major), #*. strips up to the first
#                                    dot (minor). No awk/cut needed.
#   one minor at a time              the EKS API rejects a skipped minor, and the data plane (nodes, add-ons) must follow the control plane
#                                    in order. Catching it at plan time beats a failed apply halfway.
#   list-insights UPGRADE_READINESS  EKS itself scans audit logs for calls to APIs that disappear in the next version and checks add-on
#                                    compatibility. Status values: PASSING · WARNING · ERROR · UNKNOWN. ERROR blocks, WARNING is shown.
#   kubent --target-version          open-source "kube-no-trouble": lists live objects using APIs removed in the target version.
#   why BEFORE approval              the approver then sees a plan that is also known to be upgrade-safe; and a block here costs nothing,
#                                    whereas a block after apply cannot be undone (control-plane upgrades are one-way).
# ════════════════════════════════════════════════════════════════════════
