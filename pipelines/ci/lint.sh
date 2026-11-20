#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 3 · Format & lint        (catches in 5 seconds what a reviewer spends 5 minutes on — HARD FAIL)
#  For every layer that has changed stacks:
#    1. terraform fmt -check -recursive   on infra-live/<layer> and infra-modules/<layer>
#    2. tflint                            on every changed leaf + the layer's modules   (rules: pipelines/config/tflint.hcl)
#    3. cfn-lint                          on the CloudFormation templates that live inside modules (conformance packs, StackSets)
#    4. repo hygiene                      · no real 12-digit AWS account id anywhere in git (aliases only)
#                                         · every leaf's component is named in an order file (else the pipeline can't place it)
#  Reads : .ci/changed_stacks.txt
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -s "$CHANGED_FILE" ] || { log "nothing to lint"; exit 0; }
need terraform tflint

fail=0
layers="$(cut -d/ -f1 "$CHANGED_FILE" | sort -u)"

# 1. fmt — `-check` makes it exit non-zero instead of rewriting; `-diff` shows the reviewer exactly what to change
for L in $layers; do
  for d in "$LIVE/$L" "$MODS/$L"; do
    [ -d "$d" ] || continue
    log "terraform fmt -check  ${d#$ROOT/}"
    terraform fmt -check -diff -recursive -no-color "$d" || fail=1
  done
done

# 2. tflint — plugins once, then each changed leaf (remote modules are NOT downloaded: they are linted as modules below)
tflint --init --config "$ROOT/pipelines/config/tflint.hcl" >/dev/null
while IFS= read -r s; do
  [ -n "$s" ] || continue
  log "tflint  $s"
  tflint --chdir "$LIVE/$s" --config "$ROOT/pipelines/config/tflint.hcl" --call-module-type=none --format compact || fail=1
done < "$CHANGED_FILE"
for L in $layers; do
  [ -d "$MODS/$L" ] || continue
  log "tflint --recursive  infra-modules/$L"
  tflint --chdir "$MODS/$L" --config "$ROOT/pipelines/config/tflint.hcl" --recursive --format compact || fail=1
done

# 3. cfn-lint — only where CloudFormation exists (L1: conformance pack, StackSet baseline)
cfn_files="$(for L in $layers; do find "$MODS/$L" -type f \( -path '*/templates/*.yaml' -o -path '*/conformance/*.yaml' \) 2>/dev/null; done)"
if [ -n "$cfn_files" ]; then
  need cfn-lint
  log "cfn-lint on $(printf '%s\n' "$cfn_files" | grep -c .) template(s)"
  # shellcheck disable=SC2086
  printf '%s\n' "$cfn_files" | while IFS= read -r f; do cfn-lint "$f" || exit 1; done || fail=1
fi

# 4a. no real account ids in git — aliases (DEV_ACCOUNT …) only; the real map is a CI secret file
hits="$(grep -rEn --include='*.tf' --include='*.yaml' --include='*.yml' --include='*.sh' --include='*.groovy' --include='Jenkinsfile*' --include='*.rego' --include='*.md' \
         '(^|[^0-9])[0-9]{12}([^0-9]|$)' "$ROOT/infra-live" "$ROOT/infra-modules" "$ROOT/pipelines" "$ROOT/policy" 2>/dev/null | head -5 || true)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" >&2
  warn "a 12-digit number is committed above — if it is an AWS account id, replace it with its alias (DEV_ACCOUNT …)"
  fail=1
fi

# 4b. every leaf component must appear in an order file of its layer
for L in $layers; do
  ( cd "$LIVE" && find "$L" -mindepth 4 -maxdepth 4 -name main.tf | sed 's|/main.tf$||' ) | while IFS= read -r s; do
    found=""
    for o in $(layer_orders "$L"); do [ -z "$(order_of_stack "$o" "$s")" ] || found=1; done
    [ -n "$found" ] || { log "ERROR: $s is in no ci/order/*.order file"; exit 1; }
  done || fail=1
done

[ "$fail" = 0 ] || die "format & lint failed"
log "format & lint OK"

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   terraform fmt -check -diff -recursive   fmt normalises spacing/alignment. -check = "report, don't rewrite" (a pipeline must never
#                              change code); -diff prints the patch; -recursive walks sub-folders (modules/templates).
#   tflint --init / --config   downloads the AWS ruleset plugin named in tflint.hcl, then applies it (deprecated args, invalid
#                              instance types, missing required_providers …). Cheap, offline from AWS, catches real mistakes.
#   --call-module-type=none    tflint would otherwise try to download the git module the leaf points at; we lint modules separately.
#   cfn-lint                   CloudFormation's linter — used only for the YAML templates that Terraform hands to CFN
#                              (aws_cloudformation_stack_set, aws_config_organization_conformance_pack).
#   the 12-digit grep          the class of leak that ends careers: an account id in git. We keep aliases in git and real ids in a
#                              secret file, so ANY 12-digit run in these folders is a finding. The regex needs a non-digit on both
#                              sides so a 13-digit timestamp does not trigger it.
#   order-file coverage        see detect_changed_stacks.sh — enforced for the WHOLE layer here so a new component can't be merged
#                              without deciding where it sits in the apply order.
#   `|| fail=1` instead of exit   run ALL checks and report every problem in one build, then fail once at the end.
# ════════════════════════════════════════════════════════════════════════
