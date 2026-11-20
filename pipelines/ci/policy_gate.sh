#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 9 · Policy gate     (OPA / Conftest on the PLAN JSON, not on the HCL — HARD FAIL)
#  The plan knows the RESOLVED values, so rules can assert on what will actually exist: no 0.0.0.0/0 on 22, encryption on,
#  mandatory tags present, no public S3, no IAM "*:*", no delete of a protected resource in prod.
#  Rules : policy/*.rego      Pre-approved exceptions: policy/data/exceptions.json (changed only through a reviewed PR)
#  Reads : .work/<id>/tfplan.json for every changed leaf        Writes: .ci/policy.txt (archived)
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -s "$CHANGED_FILE" ] || { log "nothing to check"; exit 0; }
need conftest

fail=0; : > "$STATE_DIR/policy.txt"
while IFS= read -r s; do
  [ -n "$s" ] || continue
  f="$WORK/$(stack_id "$s")/tfplan.json"
  if [ ! -f "$f" ]; then warn "no tfplan.json for $s (did its plan fail?)"; fail=1; continue; fi
  log "conftest  $s"
  # deny[...] → exit 1 (fail the gate) · warn[...] → printed, exit 0
  conftest test "$f" --policy "$POLICY_DIR" --data "$POLICY_DIR/data" --no-color 2>&1 | sed "s|^|[$s] |" | tee -a "$STATE_DIR/policy.txt" >&2 || fail=1
done < "$CHANGED_FILE"

[ "$fail" = 0 ] || die "policy gate FAILED — fix the findings above (or, for a legitimate exception, add it to policy/data/exceptions.json via a reviewed PR)"
log "policy gate OK"

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   conftest test <file> --policy <dir>   loads every .rego file in the directory and evaluates the rules in `package main` against the
#                              input document (here: the plan JSON). A rule `deny contains msg if { … }` that produces any message =
#                              a violation → non-zero exit. `warn` rules print but pass.
#   --data policy/data         extra JSON available to rules as data.* — here the exceptions list. Keeping exceptions in DATA (not in the
#                              Rego) lets a reviewer approve "this one resource may break rule X" without touching the rule logic.
#   why the plan JSON, not HCL HCL says `cidr_blocks = var.office_cidrs`; the plan says `["0.0.0.0/0"]`. Policy must judge the value
#                              that will exist. Same reason resource tags are read from `tags_all` (provider default_tags merged in).
#   why before approval        the approver should see a plan that already passed the machine checks; humans review intent, not typos.
#   `| tee -a … >&2 || fail=1` keep going through every leaf so one run lists ALL violations; fail once at the end.
# ════════════════════════════════════════════════════════════════════════
