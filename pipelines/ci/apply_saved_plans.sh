#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 11 · Apply the SAVED plan, in dependency order        usage: apply_saved_plans.sh <order-name>   e.g. platform | edge | edge-dns
#  * Applies ONLY `terraform apply tfplan` — the exact plan the reviewer saw and the policy gate evaluated. NEVER a bare apply.
#  * Order comes from ci/order/<order-name>.order; leaves that share a rank (`a | b`) apply in parallel, ranks apply one after another.
#  * The first failure STOPS the run. Terraform has no transaction to roll back: the script prints what was applied and what is
#    still pending, and a HUMAN decides (fix forward, or `git revert` + re-apply — the only real rollback).
#  Reads : .ci/apply_stacks.txt (from plan_all.sh) · .work/<id>/tfplan        Writes: .ci/applied_stacks.txt
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need terraform

if [ "${1:-}" = "--one" ]; then                       # ───── worker: apply ONE saved plan ─────
  stack="$2"; id="$(stack_id "$stack")"; wd="$WORK/$id"
  [ -f "$wd/tfplan" ] || die "no saved plan for $stack — plan_all.sh must run first (a bare apply is forbidden)"
  cd "$wd"
  terraform apply -input=false -no-color -lock-timeout=5m tfplan 2>&1 | sed "s|^|[$id] |"
  exit 0
fi

order="${1:?usage: apply_saved_plans.sh <order-name>}"
[ -f "$CI_DIR/order/$order.order" ] || die "no such order file: ci/order/$order.order"
[ -s "$APPLY_FILE" ] || { log "no stack has changes — nothing to apply"; exit 0; }
[ "$TARGET_ACTION" = apply ] || die "refusing to apply: ACTION is '$TARGET_ACTION'"
load_aws; load_tf_secrets; git_auth

# the leaves of THIS order file that have changes, as "rank<TAB>stack", lowest rank first
queue="$STATE_DIR/apply_queue_$order.txt"; : > "$queue"
while IFS= read -r s; do
  [ -n "$s" ] || continue
  r="$(order_of_stack "$order" "$s")"
  if [ -n "$r" ]; then printf '%s\t%s\n' "$r" "$s" >> "$queue"; fi
done < "$APPLY_FILE"
[ -s "$queue" ] || { log "nothing to apply under order '$order'"; exit 0; }
sort -t "$(printf '\t')" -k1,1n -k2,2 "$queue" -o "$queue"

done_list="$STATE_DIR/applied_stacks.txt"; touch "$done_list"
for r in $(cut -f1 "$queue" | sort -nu); do
  group="$(awk -F'\t' -v r="$r" '$1 == r { print $2 }' "$queue")"
  log "── apply group (rank $r): $(printf '%s' "$group" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  if ! printf '%s\n' "$group" | xargs -P "$PLAN_PARALLEL" -I{} bash "${BASH_SOURCE[0]}" --one {}; then
    log "applied so far:"; sed 's/^/    ✔ /' "$done_list" >&2
    log "still pending:"; awk -F'\t' -v r="$r" '$1 >= r { print "    … " $2 }' "$queue" >&2
    die "apply FAILED in group $r — NO auto-rollback. The state is partially applied: page a human; recover by fixing forward or git revert + re-apply"
  fi
  printf '%s\n' "$group" >> "$done_list"
done
log "apply OK ($order): $(grep -c . "$queue") stack(s)"

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   terraform apply tfplan      handing apply a PLAN FILE means: do exactly these actions, ask nothing, re-plan nothing. If the state
#                               changed since the plan (someone applied in between) Terraform refuses with "Saved plan is stale" —
#                               that is the safety net: the review no longer matches reality, so plan again.
#   why never a bare apply      a bare `terraform apply` re-plans at apply time: you would ship something no human reviewed and no policy
#                               evaluated. Saved plan = the review is the artifact.
#   rank groups                 `rds-aurora | dynamodb | msk …` share a rank and run in parallel (they do not depend on each other);
#                               `eks-cluster` has a higher rank and waits. This is the dependency DAG from the notes, as a file.
#   awk -F'\t' -v r="$r"        picks the stacks of one rank out of the queue file.
#   stop at the first failed group   later groups depend on earlier ones; continuing would apply things on top of a half-built base.
#   "NO auto-rollback"          Terraform has no rollback. The honest options are fix-forward or `git revert` + a new apply — both start from
#                               a commit, which is why every apply must come from one.
#   destroy                     deliberately absent: this pipeline cannot destroy. Destroy is the REVERSE of the order file and is a
#                               separate, manual, double-approved action (delete the k8s Services/Ingress first so load-balancer ENIs
#                               go away, otherwise the VPC cannot be removed).
# ════════════════════════════════════════════════════════════════════════
