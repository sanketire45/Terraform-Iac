#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 5 · Security scan     (scans the SOURCE — HIGH + CRITICAL fail the build, LOW/MEDIUM only warn)
#  Tool  : trivy config (IaC misconfiguration scanner).  Exceptions: pipelines/config/trivyignore.yaml — every entry
#          needs a written reason and an expiry date, reviewed through CODEOWNERS.
#  Scans : infra-modules/<layer>  (where the resources are defined)  +  each changed leaf (backend/provider/inputs)
#  Reads : .ci/changed_stacks.txt
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -s "$CHANGED_FILE" ] || { log "nothing to scan"; exit 0; }
need trivy

ignore="$ROOT/pipelines/config/trivyignore.yaml"
targets="$STATE_DIR/scan_targets.txt"; : > "$targets"
for L in $(cut -d/ -f1 "$CHANGED_FILE" | sort -u); do
  if [ -d "$MODS/$L" ]; then printf '%s\n' "$MODS/$L" >> "$targets"; fi
done
while IFS= read -r s; do
  if [ -n "$s" ]; then printf '%s\n' "$LIVE/$s" >> "$targets"; fi
done < "$CHANGED_FILE"

fail=0
grep . "$targets" | while IFS= read -r t; do
  log "trivy config  ${t#$ROOT/}"
  # gate: HIGH+CRITICAL → exit code 1
  trivy config --quiet --severity HIGH,CRITICAL --exit-code 1 --ignorefile "$ignore" --skip-dirs '**/.terraform' "$t" || exit 1
  # information: LOW+MEDIUM → printed, never fails (warn + annotate)
  trivy config --quiet --severity LOW,MEDIUM --exit-code 0 --ignorefile "$ignore" --skip-dirs '**/.terraform' --format table "$t" \
    | grep -E 'Failures:|MEDIUM|LOW' | head -3 || true
done || fail=1

[ "$fail" = 0 ] || die "security scan found HIGH/CRITICAL misconfigurations — fix them, or add a reviewed, expiring entry to pipelines/config/trivyignore.yaml"
log "security scan OK"

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   why scan the SOURCE here   this stage runs BEFORE any plan, so it needs no credentials and finishes in seconds. The plan-time
#                              checks (stage 9, policy gate) look at resolved values; this one looks at what the code literally says.
#   trivy config               the successor of tfsec: reads .tf (and CFN/Kubernetes YAML) and applies the AVD misconfiguration rules.
#   --severity HIGH,CRITICAL --exit-code 1     "fail on HIGH+": exit non-zero only if a finding at those levels exists.
#   second run, LOW,MEDIUM --exit-code 0       the notes' fail-vs-warn table: lower severities are visible but never block a PR.
#   --ignorefile trivyignore.yaml              the reviewed skip-list. Rule: reason + owner + expiry on every line.
#   --skip-dirs '**/.terraform'                never scan downloaded providers/modules.
#   fail=0 … || fail=1         the loop runs in a pipe (sub-shell), so it reports via its exit status instead of a variable.
# ════════════════════════════════════════════════════════════════════════
