#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 12 · Verify & publish         usage: verify_and_publish.sh <bootstrap|global|network|platform|addons|edge>
#  After an apply, prove the result is real and leave a trail:
#    1. CONVERGED?     re-plan every applied leaf — it must now report "no changes" (exit 0). A residual diff = a perpetual diff / drift.
#    2. CONTRACT       the SSM keys the layer is supposed to publish (/<org>/<env>/<segment>/*) exist — downstream layers read them.
#    3. SMOKE          layer-specific: network → contract only · platform → EKS ACTIVE · addons → kube-system Available · edge → SMOKE_URL
#    4. PROVENANCE     /<org>/<scope>/ops/last_apply/<layer> = commit + build + time ;  git tag deployed/<layer>/<scope> = the diff base next time
#  Failure mode (notes §2.12): WARN, not fail — the apply already happened and cannot be undone by failing the build.
#  Set VERIFY_STRICT=true to turn the warnings into a failed build.
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
layer_name="${1:?usage: verify_and_publish.sh <layer-name>}"
need terraform jq aws git
applied="$STATE_DIR/applied_stacks.txt"
[ -s "$applied" ] || { log "nothing was applied — nothing to verify"; exit 0; }
load_tf_secrets; git_auth
sha="$(cat "$STATE_DIR/git_sha" 2>/dev/null || git -C "$ROOT" rev-parse HEAD)"
problems=0
flag() { warn "$*"; problems=$((problems + 1)); }

# 1 ── converged? (no residual diff after our own apply)
while IFS= read -r s; do
  [ -n "$s" ] || continue
  wd="$WORK/$(stack_id "$s")"
  set +e; ( load_aws "$s"; cd "$wd" && terraform plan -input=false -no-color -lock-timeout=5m -detailed-exitcode >"$wd/verify-plan.txt" 2>&1 ); rc=$?; set -e
  case "$rc" in
    0) log "converged: $s" ;;
    2) flag "$s still shows a diff after apply (perpetual diff or concurrent change) — see .work/$(stack_id "$s")/verify-plan.txt" ;;
    *) flag "$s: the verification plan itself failed (rc=$rc)" ;;
  esac
done < "$applied"

# 2 ── contract keys exist where the module says it publishes them
while IFS= read -r s; do
  [ -n "$s" ] || continue
  mod="$( { grep -hoE 'infra-modules/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+\?ref=' "$LIVE/$s/main.tf" || true; } | head -1 | sed -E 's#^infra-modules/##; s#\?ref=$##')"
  [ -n "$mod" ] && [ -f "$MODS/$mod/main.tf" ] || continue
  tpl="$( { grep -hoE 'ssm_prefix *= *"[^"]+"' "$MODS/$mod/main.tf" || true; } | head -1 | sed -E 's/.*= *"//; s/"$//')"
  [ -n "$tpl" ] || continue                                   # this module publishes nothing
  scope="$(printf '%s' "$s" | cut -d/ -f2)"; region="$(printf '%s' "$s" | cut -d/ -f3)"
  case "$scope" in _shared) envname=shared ;; *) envname="$scope" ;; esac
  prefix="$(printf '%s' "$tpl" | sed "s#\${var.org}#$ORG#g; s#\${var.env}#$envname#g")"
  n="$( ( eval "$(exec_env "$s")"; aws ssm get-parameters-by-path --path "$prefix" --recursive --region "${region/_/us-east-2}" --query 'length(Parameters)' --output text ) 2>/dev/null || echo 0)"
  if [ "${n:-0}" -ge 1 ] 2>/dev/null; then log "contract ok: $prefix ($n keys)"; else flag "no SSM keys under $prefix after applying $s — downstream layers will fail"; fi
done < "$applied"

# 3 ── smoke tests, per layer
smoke_url="${SMOKE_URL:-}"
case "$layer_name" in
  platform)
    { grep -E '/eks-cluster$' "$applied" || true; } | while IFS= read -r s; do
      env_="$(printf '%s' "$s" | cut -d/ -f2)"; region="$(printf '%s' "$s" | cut -d/ -f3)"
      st="$( ( eval "$(exec_env "$s")"; aws eks describe-cluster --name "$env_-eks" --region "$region" --query cluster.status --output text ) 2>/dev/null || echo UNKNOWN)"
      [ "$st" = ACTIVE ] && log "EKS $env_-eks is ACTIVE" || { warn "EKS $env_-eks status is $st"; exit 1; }
    done || problems=$((problems + 1)) ;;
  addons)
    need kubectl
    printf '%s\n' "$(head -1 "$applied")" | while IFS= read -r s; do
      env_="$(printf '%s' "$s" | cut -d/ -f2)"; region="$(printf '%s' "$s" | cut -d/ -f3)"
      ( eval "$(exec_env "$s")"; export KUBECONFIG="$STATE_DIR/kubeconfig"
        aws eks update-kubeconfig --name "$env_-eks" --region "$region" --kubeconfig "$KUBECONFIG" >/dev/null
        kubectl wait --for=condition=Available deployment --all -n kube-system --timeout=180s ) || exit 1
    done || flag "kube-system deployments are not all Available after the add-on apply" ;;
  edge)
    if [ -n "$smoke_url" ]; then
      code="$(curl -sS -o /dev/null -m 20 -w '%{http_code}' "$smoke_url" || echo 000)"
      case "$code" in 2*|3*|401|403) log "smoke $smoke_url → HTTP $code" ;; *) flag "smoke $smoke_url → HTTP $code" ;; esac
    else log "SMOKE_URL not set — edge smoke test skipped"; fi ;;
  global)   "$CI_DIR/scp_lockout_check.sh" --post || flag "post-apply lock-out probe failed — see the message above" ;;
  bootstrap) log "bootstrap layer is not part of this copy — nothing to verify" ;;
esac

# 4 ── provenance: SSM marker + the git tag the NEXT run diffs from
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cut -d/ -f1-2 "$applied" | sort -u | while IFS= read -r ls_; do
  L="${ls_%%/*}"; scope="${ls_#*/}"
  first="$(grep -m1 "^$ls_/" "$applied")"
  region="$(printf '%s' "$first" | cut -d/ -f3)"; [ "$region" = _ ] && region=us-east-2
  case "$scope" in _shared) envname=shared ;; *) envname="$scope" ;; esac
  ( eval "$(exec_env "$first")"
    aws ssm put-parameter --name "/$ORG/$envname/ops/last_apply/$layer_name" --type String --overwrite --region "$region" \
        --value "commit=$sha build=${BUILD_TAG:-manual} at=$now" >/dev/null ) || flag "could not write the last_apply marker for $ls_"
  git -C "$ROOT" tag -f "deployed/$L/$scope" "$sha" >/dev/null
  if [ "${PUSH_DEPLOY_TAGS:-false}" = true ] && git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
    git -C "$ROOT" push -f origin "refs/tags/deployed/$L/$scope" >/dev/null 2>&1 || flag "could not push tag deployed/$L/$scope"
  fi
  log "marked deployed/$L/$scope = $(printf '%s' "$sha" | cut -c1-12)"
done

if [ "$problems" != 0 ]; then
  [ "${VERIFY_STRICT:-false}" = true ] && die "verification found $problems problem(s) (VERIFY_STRICT=true)"
  warn "verification finished with $problems warning(s) — the apply itself succeeded"
else
  log "verify & publish OK"
fi

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   re-plan → exit 0             after a successful apply the configuration and the real world must agree. -detailed-exitcode=2 means
#                                Terraform still wants to change something: usually a perpetual diff (a provider normalising a value) or
#                                something else changing the same resource. It is the cheapest idempotency test there is.
#   exec_env + `eval`            the smoke tests are plain AWS CLI calls, so they need the TARGET account's terraform-exec session; exec_env
#                                prints `export AWS_…` lines for it and the subshell `( eval … ; aws … )` keeps those credentials from
#                                leaking into the rest of the script.
#   ssm_prefix from the module   the verifier reads the path template out of the module's own PUBLISH block, so it can never disagree
#                                with what the module really writes.
#   last_apply marker + tag      "refresh the drift baseline": the SSM value says WHAT is deployed; the git tag deployed/<layer>/<scope>
#                                lets detect_changed_stacks.sh compute "what has this environment not received yet" exactly.
#   warn, don't fail             the apply is already done; a red build cannot undo it. But a warning is never silent: it is counted
#                                and printed, and VERIFY_STRICT=true makes it fatal for pipelines that want that.
#   kubectl wait --for=condition=Available deployment --all     blocks until every kube-system Deployment reports Available (or times out).
# ════════════════════════════════════════════════════════════════════════
