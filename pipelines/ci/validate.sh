#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 4 · Validate     (syntax + provider schema — needs NO cloud credentials, HARD FAIL)
#  For each changed leaf:  build a throw-away working copy → swap account ALIASES for dummy ids (the provider schema checks ARN
#  shape) → terraform init -backend=false → terraform validate.   Leaves run in parallel (PLAN_PARALLEL).
#  Reads : .ci/changed_stacks.txt      Env: TF_PLUGIN_DIR (offline provider mirror), LOCAL_MODULES_ALL=true (also use local modules for tagged refs)
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need terraform

if [ "${1:-}" = "--one" ]; then            # worker: validate ONE leaf (called by xargs below)
  stack="$2"; id="$(stack_id "$stack")"
  wd="$(make_workdir "$stack" "$LIVE" "$MODS" "$WORK/validate")"
  render_aliases "$wd" dummy
  ( cd "$wd" && terraform init -backend=false "${TF_INIT_ARGS[@]}" >/dev/null && terraform validate -no-color ) 2>&1 | sed "s|^|[$id] |"
  exit 0
fi

[ -s "$CHANGED_FILE" ] || { log "nothing to validate"; exit 0; }
git_auth
log "validating $(grep -c . "$CHANGED_FILE") stack(s), $PLAN_PARALLEL at a time"
set +e
grep . "$CHANGED_FILE" | xargs -P "$PLAN_PARALLEL" -I{} bash "${BASH_SOURCE[0]}" --one {} | tee "$STATE_DIR/validate.log"
rc=$?
set -e
# `terraform validate` prints "Success!" per leaf; anything else (Error:) means a broken leaf. xargs exits 123 if a worker failed.
bad="$(grep -c 'Error' "$STATE_DIR/validate.log" || true)"
if [ "$rc" != 0 ] || [ "$bad" != 0 ]; then die "validate failed ($bad error line(s)) — see the log above"; fi
log "validate OK"

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   `--one` worker pattern     the script calls ITSELF through xargs -P N: one process per leaf, N at a time. xargs is the simplest
#                              portable "parallel with a cap" there is (Jenkins `parallel {}` in Groovy would work too, but then
#                              the logic lives in Groovy instead of in a script you can run on your laptop).
#   make_workdir               never validate in the git checkout: init writes .terraform/ and lock files, and we rewrite module
#                              sources. A copy keeps the checkout clean and lets every leaf run side by side.
#   render_aliases … dummy     DEV_ACCOUNT → a fake 12-digit id. `validate` runs the provider's schema checks (ARN format!) so a literal
#                              alias would fail even though the code is right. Real ids are not needed — and not available — here.
#   init -backend=false        skip the S3 backend: validate must not touch state or need credentials. That is exactly why this
#                              stage can run on a fork's PR without secrets.
#   TF_INIT_ARGS               -plugin-dir=… when TF_PLUGIN_DIR is set (an array, so paths with spaces survive): an offline provider mirror (air-gapped agents / local tests).
#   sed "s|^|[id] |"           prefixes every line with the leaf id so interleaved parallel output stays readable.
# ════════════════════════════════════════════════════════════════════════
