#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 6 · Cost estimate      (Infracost diff vs the base — fails ONLY above a threshold; "this PR adds $4,100/mo")
#  How   : build the changed leaves from the BASE commit and from HEAD, price both, diff them.
#  Env   : INFRACOST_API_KEY (CI secret) · COST_FAIL_USD_PER_MONTH (default 1000) · COST_WARN_USD_PER_MONTH (default 200)
#          COST_GATE=off disables the stage explicitly (never silently skip a gate)
#  Reads : .ci/changed_stacks.txt   Writes: .ci/cost-diff.json, .ci/cost.txt (archived by the Jenkinsfile)
#  Note  : Infracost reads the HCL (no cloud credentials). Values that come from SSM at plan time are unknown here, so counts that
#          depend on them are estimated from defaults — treat the number as an order-of-magnitude guard, not an invoice.
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -s "$CHANGED_FILE" ] || { log "nothing to price"; exit 0; }
if [ "${COST_GATE:-on}" = off ]; then warn "COST_GATE=off — cost gate disabled by the job configuration"; exit 0; fi
need infracost jq git
[ -n "${INFRACOST_API_KEY:-}" ] || die "INFRACOST_API_KEY missing — provide it as a CI secret, or set COST_GATE=off on purpose"

FAIL="${COST_FAIL_USD_PER_MONTH:-1000}"; WARN="${COST_WARN_USD_PER_MONTH:-200}"
git_auth

# 1. the base tree: the same folders as they were at the diff base (new stacks simply do not exist there → priced as 0)
base="${BASE_SHA:-}"
[ -n "$base" ] || base="$(git -C "$ROOT" merge-base HEAD "origin/${CHANGE_TARGET:-main}" 2>/dev/null || git -C "$ROOT" rev-parse -q --verify HEAD~1 2>/dev/null || true)"
bt="$STATE_DIR/base-tree"; rm -rf "$bt"; mkdir -p "$bt"
if [ -n "$base" ]; then
  git -C "$ROOT" archive "$base" infra-live infra-modules 2>/dev/null | tar -x -C "$bt" || true
fi

# 2. an Infracost config per side: one project per leaf (working copies, so floating module refs point at the right local tree)
cfg() {   # cfg <live-root> <modules-root> <dest-dir> <out-file>
  { echo "version: 0.1"; echo "projects:"
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      [ -d "$1/$s" ] || continue
      wd="$(make_workdir "$s" "$1" "$2" "$3")"; render_aliases "$wd" dummy
      echo "  - path: $wd"
    done < "$CHANGED_FILE"; } > "$4"
}
cfg "$LIVE" "$MODS" "$STATE_DIR/cost-head" "$STATE_DIR/infracost-head.yml"
cfg "$bt/infra-live" "$bt/infra-modules" "$STATE_DIR/cost-base" "$STATE_DIR/infracost-base.yml"

# 3. price both sides, then diff
infracost breakdown --config-file "$STATE_DIR/infracost-base.yml" --format json --out-file "$STATE_DIR/cost-base.json" --no-color >/dev/null
infracost diff --config-file "$STATE_DIR/infracost-head.yml" --compare-to "$STATE_DIR/cost-base.json" --format json --out-file "$STATE_DIR/cost-diff.json" --no-color >/dev/null
infracost output --path "$STATE_DIR/cost-diff.json" --format table --no-color > "$STATE_DIR/cost.txt" || true
cat "$STATE_DIR/cost.txt"

# 4. the gate
delta="$(jq -r '.diffTotalMonthlyCost // "0"' "$STATE_DIR/cost-diff.json")"
log "monthly cost change of this change set: ≈ \$$delta   (warn ≥ \$$WARN, fail ≥ \$$FAIL)"
over() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }
if over "$delta" "$FAIL"; then die "cost gate: +\$$delta/month exceeds the \$$FAIL threshold — get a cost approval, or reduce the change"; fi
if over "$delta" "$WARN"; then warn "cost gate: +\$$delta/month is above the \$$WARN warning level"; fi

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   git archive <base> | tar -x      exports a clean copy of infra-live + infra-modules AS THEY WERE at the base commit, without
#                                    touching the working tree. Stacks added by this PR are absent there → their whole cost is "new".
#   the Infracost config file        `projects: - path:` per leaf. Each leaf is built through make_workdir(), which rewrites the floating
#                                    module ref to the matching local tree (HEAD tree for the head side, the base tree for the base side).
#   infracost breakdown  → json      prices the base side once and saves it …
#   infracost diff --compare-to      … then prices HEAD and reports only the DIFFERENCE against that saved baseline.
#   .diffTotalMonthlyCost            the number the gate reads. awk does the float comparison (bash only does integers).
#   fail only over a threshold       the notes' rule: a cost gate that blocks every PR gets switched off; one that blocks only the big
#                                    surprises stays on. Below FAIL but above WARN → annotate, don't block.
#   COST_GATE=off                    an explicit, visible opt-out in the job config. A missing API key is an ERROR, never a silent skip.
# ════════════════════════════════════════════════════════════════════════
