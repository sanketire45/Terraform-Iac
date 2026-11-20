#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 2 · Detect changed stacks      usage: detect_changed_stacks.sh <layer-folder>   e.g. L5-edge-app
#  Decides WHICH leaves (infra-live/<layer>/<scope>/<region>/<component>) this build touches, then orders them by the layer's
#  ci/order/*.order file. Nothing to do → writes an empty list and exits GREEN (the Jenkinsfile then skips the rest).
#
#  Inputs (env): TARGET_ENV   dev|qa|stage|stage-dr|prod|_shared|org|tooling|any      (any = no environment filter)
#                TARGET_REGION eu-west-1 | _ | any
#                COMPONENT    "all" or a comma list of component folders (explicit request: ignores the git diff)
#                ALL_STACKS   true = every leaf in scope, ignore the diff (re-run / first deploy / after an outage)
#                BASE_SHA     override the diff base;  CHANGE_ID / CHANGE_TARGET  set by Jenkins on PR builds
#  Output      : .ci/changed_stacks.txt  — one leaf path per line, in apply order
#
#  What counts as "changed":
#    infra-live/<layer>/…        → that leaf
#    infra-modules/<layer>/<m>/… → every leaf of this layer that FLOATS on that module (?ref=main).  Leaves pinned to a tag
#                                  (qa/stage/prod) are NOT affected until their ref is bumped — that is the whole point of pinning.
#    policy/** or pipelines/**   → every leaf in scope (the gates/tooling changed, so re-test everything)
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need git
layer="${1:?usage: detect_changed_stacks.sh <layer-folder>}"
[ -d "$LIVE/$layer" ] || die "no such layer folder: infra-live/$layer"
ALL_STACKS="${ALL_STACKS:-false}"

tmp="$STATE_DIR/detect"; mkdir -p "$tmp"
: > "$tmp/all.txt"; : > "$tmp/scope.txt"; : > "$tmp/cand.txt"

# 1. every leaf of the layer (layer/scope/region/component, one main.tf each)
( cd "$LIVE" && find "$layer" -mindepth 4 -maxdepth 4 -name main.tf | sed 's|/main.tf$||' | sort ) > "$tmp/all.txt"

# 2. …inside the requested environment / region
while IFS= read -r s; do
  sc="$(printf '%s' "$s" | cut -d/ -f2)"; rg="$(printf '%s' "$s" | cut -d/ -f3)"
  [ "$TARGET_ENV" = any ]    || [ "$sc" = "$TARGET_ENV" ]    || continue
  [ "$TARGET_REGION" = any ] || [ "$rg" = "$TARGET_REGION" ] || continue
  printf '%s\n' "$s"
done < "$tmp/all.txt" > "$tmp/scope.txt"
[ -s "$tmp/scope.txt" ] || log "no leaves exist in $layer for env=$TARGET_ENV region=$TARGET_REGION"

# 3. which of them are candidates?
resolve_base() {
  if   [ -n "${BASE_SHA:-}" ];  then printf '%s' "$BASE_SHA"
  elif [ -n "${CHANGE_ID:-}" ]; then git -C "$ROOT" merge-base HEAD "origin/${CHANGE_TARGET:-main}" 2>/dev/null || true
  elif [ "$TARGET_ENV" != any ] && git -C "$ROOT" rev-parse -q --verify "refs/tags/deployed/$layer/$TARGET_ENV" >/dev/null 2>&1; then
       git -C "$ROOT" rev-parse "refs/tags/deployed/$layer/$TARGET_ENV^{commit}"      # last successful apply of THIS layer+env
  elif [ -n "${GIT_PREVIOUS_SUCCESSFUL_COMMIT:-}" ]; then printf '%s' "$GIT_PREVIOUS_SUCCESSFUL_COMMIT"
  else git -C "$ROOT" rev-parse -q --verify HEAD~1 2>/dev/null || true
  fi
}

consumers() {   # consumers <layer/module> → leaves of this layer that float on it
  grep -rlF --include=main.tf "infra-modules.git//$1?ref=main" "$LIVE/$layer" 2>/dev/null \
    | sed "s|^$LIVE/||; s|/main.tf$||" || true
}

if [ "$COMPONENT" != all ]; then
  log "explicit COMPONENT=$COMPONENT (the git diff is ignored)"
  for c in $(printf '%s' "$COMPONENT" | tr ',' ' '); do
    n0="$(wc -l < "$tmp/cand.txt" | tr -d ' ')"
    awk -F/ -v c="$c" '$NF == c' "$tmp/scope.txt" >> "$tmp/cand.txt"          # exact match on the last path part — never a regex built from user input
    [ "$(wc -l < "$tmp/cand.txt" | tr -d ' ')" -gt "$n0" ] || die "component '$c' has no leaf in $layer for env=$TARGET_ENV region=$TARGET_REGION"
  done
elif [ "$ALL_STACKS" = true ]; then
  log "ALL_STACKS=true → every leaf in scope"
  cp "$tmp/scope.txt" "$tmp/cand.txt"
else
  base="$(resolve_base)"
  if [ -z "$base" ]; then
    log "no diff base found (first run?) → treating every leaf in scope as changed"
    cp "$tmp/scope.txt" "$tmp/cand.txt"
  else
    log "diff base: $(printf '%s' "$base" | cut -c1-12)  →  HEAD"
    git -C "$ROOT" diff --name-only --relative "$base" HEAD -- . > "$tmp/files.txt" || die "git diff failed (is $base in the history?)"
    while IFS= read -r f; do
      case "$f" in
        infra-live/"$layer"/*)
          printf '%s\n' "$f" | cut -d/ -f2-5 >> "$tmp/cand.txt" ;;
        infra-modules/"$layer"/*/*)
          m="$(printf '%s' "$f" | cut -d/ -f2-3)"
          consumers "$m" >> "$tmp/cand.txt"
          pinned="$(grep -rlE --include=main.tf "infra-modules\.git//$m\?ref=v" "$LIVE/$layer" 2>/dev/null | wc -l | tr -d ' ')"
          [ "$pinned" = 0 ] || log "module $m changed: $pinned leaf(s) pin a release tag and are NOT affected until their ?ref is bumped" ;;
        policy/*|pipelines/*)
          [ -n "${widened:-}" ] || log "$f changed (policy/pipeline code) → every leaf in scope is re-tested"; widened=1
          cat "$tmp/scope.txt" >> "$tmp/cand.txt" ;;
      esac
    done < "$tmp/files.txt"
  fi
fi

# 4. candidates ∩ scope, de-duplicated, then ORDERED: rank = (which order file) × 1000 + (line in it)
sort -u "$tmp/cand.txt" | grep -Fxf "$tmp/scope.txt" > "$tmp/final.txt" || true

rank_of() {
  local i=0 o r
  for o in $(layer_orders "$layer"); do
    i=$((i + 1)); r="$(order_of_stack "$o" "$1")"
    if [ -n "$r" ]; then echo $((i * 1000 + r)); return 0; fi
  done
  return 1
}
: > "$tmp/ranked.txt"
while IFS= read -r s; do
  [ -n "$s" ] || continue
  r="$(rank_of "$s")" || die "$s is not listed in any ci/order/*.order file ($(layer_orders "$layer")) — add the component, otherwise the pipeline cannot know when to apply it"
  printf '%s\t%s\n' "$r" "$s" >> "$tmp/ranked.txt"
done < "$tmp/final.txt"
sort -t "$(printf '\t')" -k1,1n -k2,2 "$tmp/ranked.txt" | cut -f2 > "$CHANGED_FILE"

n="$(grep -c . "$CHANGED_FILE" || true)"
if [ "$n" = 0 ]; then
  log "No stack changed — exiting green."
else
  log "$n stack(s) to process, in apply order:"
  sed 's/^/    /' "$CHANGED_FILE" >&2
fi

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   find … -mindepth 4 -maxdepth 4 -name main.tf   a leaf is exactly layer/scope/region/component/main.tf — nothing deeper, nothing
#                              shallower — so the path IS the state key and the ownership boundary (CODEOWNERS).
#   scope filter               the same pipeline serves every environment: ENV picks the folder, REGION the sub-folder. "any" is for PR
#                              builds, which plan whatever the PR touched in every environment (read the leaf's own provider for the role).
#   resolve_base               three-dot diff semantics, explained: on a PR the base is the MERGE-BASE with the target branch (what the PR
#                              adds), on a promotion run it is the deployed/<layer>/<env> tag (what this env has not received yet).
#   diff --name-only --relative  paths relative to the repo root even when the repo is a sub-folder of a bigger git checkout.
#   consumers() + ?ref=main    a module change widens the blast radius to every consumer — but only consumers that FLOAT on main.
#                              Tag-pinned leaves are immutable by design; they change when their ref line changes (a leaf diff).
#   rank_of / order files      "ordered apply": a leaf's rank is (order-file index)×1000 + (line number). `a | b` shares a rank = a
#                              parallel group. A component missing from every order file is a hard error — the build can't guess its
#                              place in the dependency DAG, and a wrong guess is how IRSA-before-OIDC or DNS-before-NLB happens.
#   sort -t TAB -k1,1n -k2,2   numeric by rank, then by path, so the list is deterministic.
#   exit 0 with an empty list  "nothing changed" is success, not failure; the Jenkinsfile checks the list and skips the other stages.
# ════════════════════════════════════════════════════════════════════════
