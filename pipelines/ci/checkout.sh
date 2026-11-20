#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 1 · Checkout (after Jenkins' own `checkout scm`)
#  Makes the workspace safe for `git diff`: full history + the PR target branch + the deployed/* tags,
#  and proves the agent has every tool the later stages need — a missing binary fails HERE, not 40 minutes in.
#  Env   : CHANGE_TARGET (set by Jenkins on a PR build; default main), PREFLIGHT_TOOLS (extra tools to require)
#  Writes: .ci/git_sha
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need git terraform jq aws                               # every pipeline needs these
# shellcheck disable=SC2086
[ -z "${PREFLIGHT_TOOLS:-}" ] || need $PREFLIGHT_TOOLS  # a Jenkinsfile can add its own (helm kubectl …)

# a shallow clone cannot answer "what changed since the base?" — unshallow it
if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" = true ]; then
  log "shallow clone → fetching full history"
  git -C "$ROOT" fetch --unshallow --tags --quiet
fi

# the base branch (PR target) and the deployed/<layer>/<env> tags are what detect_changed_stacks.sh diffs against
TARGET="${CHANGE_TARGET:-main}"
if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  git -C "$ROOT" fetch origin "$TARGET" --quiet || warn "could not fetch origin/$TARGET — the diff base will fall back to HEAD~1"
  git -C "$ROOT" fetch origin 'refs/tags/deployed/*:refs/tags/deployed/*' --quiet 2>/dev/null || true
else
  warn "no 'origin' remote — diffing against local history only"
fi

git -C "$ROOT" rev-parse HEAD | tee "$STATE_DIR/git_sha" >/dev/null
log "checked out $(cut -c1-12 "$STATE_DIR/git_sha") · terraform $(terraform version -json 2>/dev/null | jq -r .terraform_version 2>/dev/null || echo '?')"

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   . lib.sh                  every script starts by sourcing the shared helpers (paths, log/die/need, order reader …).
#                             `set -euo pipefail` lives in lib.sh: stop on the first error, on unset variables and on a failure
#                             anywhere inside a pipe — a CI script that keeps going after an error produces a green build that lies.
#   need git terraform …      `command -v` for each tool; fails with a clear name instead of "command not found" later.
#   rev-parse --is-shallow…   Jenkins clones with depth 1 by default. `git diff base...HEAD` needs the base commit, so unshallow.
#   fetch origin "$TARGET"    on a PR build, CHANGE_TARGET is the branch the PR merges into (usually main); we need its tip.
#   refs/tags/deployed/*      verify_and_publish.sh moves a tag deployed/<layer>/<env> after every successful apply; the next run
#                             diffs from that tag, so "what changed since PROD last got this layer" is exact, not "since HEAD~1".
#   tee git_sha               records the exact commit this build deploys (written to SSM + the chat message at the end).
# ════════════════════════════════════════════════════════════════════════
