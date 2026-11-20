#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 8 · Plan (fan-out WITHIN the layer)
#  For every changed leaf, in parallel (capped by PLAN_PARALLEL):
#     working copy → terraform init → alias→real ids → terraform plan -out=tfplan → show (text + json) → one result line
#  Then prints ONE summary table, flags destructive plans, and writes the list of leaves that really have changes.
#
#  Reads : .ci/changed_stacks.txt                       Needs: the Authenticate stage ran (.ci/aws-<scope>.env) and pipelines/config/<scope>-config.txt filled in
#  Writes: .work/<id>/{tfplan,tfplan.json,plan.txt,plan.log}   .ci/results/<id>.tsv   .ci/plan_summary.txt   .ci/apply_stacks.txt
#  Rule  : the saved plan is the ONLY thing stage 11 applies. tfplan.json holds resolved (incl. sensitive) values → it stays in the
#          workspace and is NOT archived; only the redacted plan.txt + the summary are.
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need terraform jq

if [ "${1:-}" = "--one" ]; then                       # ───── worker: plan ONE leaf ─────
  stack="$2"; id="$(stack_id "$stack")"
  mkdir -p "$STATE_DIR/results"
  wd="$(make_workdir "$stack")"
  rm -f "$wd/plan.rc"
  load_aws "$stack"                                       # the session of THIS stack's environment (written by assume_role.sh)
  (
    set +e; cd "$wd" || exit 0
    terraform init "${TF_INIT_ARGS[@]}"                || { echo 1 > plan.rc; exit 0; }
    render_aliases "$wd" real                           # AFTER init, so modules downloaded from a tag are rendered as well
    terraform plan -input=false -no-color -lock-timeout=5m -detailed-exitcode -out=tfplan
    echo $? > plan.rc                                   # 0 = no changes · 1 = error · 2 = changes present
  ) 2>&1 | sed "s|^|[$id] |" | tee "$wd/plan.log"
  rc="$(cat "$wd/plan.rc" 2>/dev/null || echo 1)"
  add=0; chg=0; del=0; rep=0
  if [ "$rc" = 0 ] || [ "$rc" = 2 ]; then
    ( cd "$wd" && terraform show -no-color tfplan > plan.txt && terraform show -json tfplan > tfplan.json )
    read -r add chg del rep <<EOF
$(jq -r '[.resource_changes[]? | select((.change.actions | index("no-op") | not) and (.change.actions | index("read") | not))] as $c
         | [ ($c | map(select(.change.actions == ["create"])) | length),
             ($c | map(select(.change.actions == ["update"])) | length),
             ($c | map(select(.change.actions == ["delete"])) | length),
             ($c | map(select((.change.actions | index("delete")) and (.change.actions | index("create")))) | length) ] | @tsv' "$wd/tfplan.json")
EOF
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$stack" "$rc" "$add" "$chg" "$del" "$rep" > "$STATE_DIR/results/$id.tsv"
  exit 0
fi

# ───── main ─────
[ -s "$CHANGED_FILE" ] || { log "nothing to plan"; exit 0; }
load_tf_secrets; git_auth
rm -rf "$STATE_DIR/results"; mkdir -p "$STATE_DIR/results"; : > "$APPLY_FILE"; : > "$STATE_DIR/applied_stacks.txt"

log "planning $(grep -c . "$CHANGED_FILE") stack(s), $PLAN_PARALLEL at a time"
grep . "$CHANGED_FILE" | xargs -P "$PLAN_PARALLEL" -I{} bash "${BASH_SOURCE[0]}" --one {} || true   # judge by the result files, not by xargs

# summary table, in apply order
sum="$STATE_DIR/plan_summary.txt"
{ printf '%-62s %-9s %4s %4s %4s %4s\n' STACK RESULT ADD CHG DEL REPL
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    f="$STATE_DIR/results/$(stack_id "$s").tsv"
    if [ -f "$f" ]; then IFS="$(printf '\t')" read -r _ rc a c d r < "$f"; else rc=1; a=-; c=-; d=-; r=-; fi
    case "$rc" in 0) res="no-change" ;; 2) res="CHANGES" ;; *) res="FAILED" ;; esac
    printf '%-62s %-9s %4s %4s %4s %4s\n' "$s" "$res" "$a" "$c" "$d" "$r"
  done < "$CHANGED_FILE"; } | tee "$sum" >&2

failed=0; destructive=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  f="$STATE_DIR/results/$(stack_id "$s").tsv"
  [ -f "$f" ] || { failed=1; continue; }
  IFS="$(printf '\t')" read -r _ rc a c d r < "$f"
  case "$rc" in 2) printf '%s\n' "$s" >> "$APPLY_FILE" ;; 0) ;; *) failed=1 ;; esac
  if [ "${d:-0}" != 0 ] || [ "${r:-0}" != 0 ]; then
    destructive=1
    warn "$s: destroys ${d:-0} and REPLACES ${r:-0} resource(s) — read plan.txt for 'must be replaced' before approving"
    grep -h 'must be replaced' "$WORK/$(stack_id "$s")/plan.txt" 2>/dev/null | head -10 | sed 's/^/        /' >&2 || true
  fi
done < "$CHANGED_FILE"
printf 'destructive=%s\n' "$destructive" > "$STATE_DIR/plan_flags.env"

[ "$failed" = 0 ] || die "plan failed for at least one stack — nothing will be applied"
log "plan OK — $(grep -c . "$APPLY_FILE" || true) stack(s) have changes to apply"

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   the plan is the artifact        terraform plan -out=tfplan writes a binary file with the exact actions AND the exact provider/module
#                                   versions and variable values. Stage 11 applies THAT file — so what the reviewer approved is what runs.
#   -detailed-exitcode              plan normally exits 0 for "ok" and 1 for "error". With this flag 2 means "ok, and there ARE changes".
#                                   That one number is how the pipeline knows which stacks need an apply (and how drift detection works).
#   -lock-timeout=5m                another run holds the state lock? wait up to 5 minutes instead of failing instantly.
#   terraform show -json            the machine-readable plan: policy_gate.sh evaluates it, and jq counts creates/updates/deletes here.
#   REPL (replace)                  actions == [delete, create]. A "small update" that is really destroy+create is the dangerous kind;
#                                   it is counted and called out loudly. `must be replaced` in plan.txt tells you WHICH attribute forced it.
#   render_aliases real             real account ids exist only inside this throw-away working copy, never in git, never in an artifact
#                                   (plan.txt/summary may show them — keep the build log access-controlled like the account map).
#   result files, not exit codes    xargs hides which worker failed; each worker leaves a one-line .tsv, and the summary is built from them.
#   tfplan.json NOT archived        it contains sensitive values in clear text; only plan.txt (redacted) and the summary table are archived.
# ════════════════════════════════════════════════════════════════════════
