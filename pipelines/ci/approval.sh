#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 10 · Approval gate — the RECORDING + RULES half.
#  The Jenkinsfile asks the human with Groovy `input(submitterParameter: 'APPROVER', …)` (a shell script cannot pause a build);
#  this script then validates what came back and writes the audit record.
#
#  Env (set by the Jenkinsfile from the input() result):
#     APPROVER           Jenkins user id that clicked Proceed (submitterParameter — cannot be spoofed by typing a name)
#     CHANGE_TICKET      the change / CR ticket the approver typed (format checked below)
#     STARTED_BY         who started the build           SECOND_APPROVER  (global pipeline) the second reviewer
#     REQUIRE_TWO=true   two DIFFERENT approvers, neither being the person who started the build   (pipeline-global always)
#     BOOTSTRAP_REASON   (pipeline-bootstrap) why this run-once pipeline is being run
#     TICKET_REGEX       default ^[A-Z][A-Z0-9]+-[0-9]+$   (e.g. CHG-12345)
#  Rules : prod ⇒ the approver must NOT be the person who started the build (four eyes) · ticket mandatory for stage/prod/org
#  Writes: .ci/approval.json (archived with the build)
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need jq

APPROVER="${APPROVER:-}"; STARTED_BY="${STARTED_BY:-}"; CHANGE_TICKET="${CHANGE_TICKET:-}"; SECOND_APPROVER="${SECOND_APPROVER:-}"
REQUIRE_TWO="${REQUIRE_TWO:-false}"; TICKET_REGEX="${TICKET_REGEX:-^[A-Z][A-Z0-9]+-[0-9]+\$}"

[ -n "$APPROVER" ] || die "no approver was recorded — the approval input did not return a submitter"

if [ -n "${BOOTSTRAP_REASON:-}" ]; then
  [ "${#BOOTSTRAP_REASON}" -ge 15 ] || die "bootstrap needs a real reason (≥15 chars) — it is a rare, high-trust run"
fi

case "$TARGET_ENV" in
  stage|stage-dr|prod|org|tooling|_shared)
    printf '%s' "$CHANGE_TICKET" | grep -Eq "$TICKET_REGEX" || die "change ticket '$CHANGE_TICKET' does not match $TICKET_REGEX" ;;
esac

# four-eyes: whoever started a prod/org/tooling build must not also approve it
case "$TARGET_ENV" in
  prod|org|tooling)
    [ -z "$STARTED_BY" ] || [ "$APPROVER" != "$STARTED_BY" ] || die "four-eyes rule: '$APPROVER' started this $TARGET_ENV build and cannot approve it" ;;
esac

if [ "$REQUIRE_TWO" = true ]; then
  [ -n "$SECOND_APPROVER" ]                  || die "two reviewers are required for this pipeline — the second approval is missing"
  [ "$SECOND_APPROVER" != "$APPROVER" ]      || die "the two approvers must be different people"
  [ -z "$STARTED_BY" ] || [ "$SECOND_APPROVER" != "$STARTED_BY" ] || die "the second approver cannot be the person who started the build"
fi

jq -n --arg env "$TARGET_ENV" --arg region "$TARGET_REGION" --arg action "$TARGET_ACTION" --arg component "$COMPONENT" \
      --arg approver "$APPROVER" --arg second "$SECOND_APPROVER" --arg started "$STARTED_BY" --arg ticket "$CHANGE_TICKET" \
      --arg reason "${BOOTSTRAP_REASON:-}" --arg build "${BUILD_TAG:-manual}" --arg sha "$(cat "$STATE_DIR/git_sha" 2>/dev/null || echo unknown)" \
      --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{approved_at:$at, build:$build, commit:$sha, env:$env, region:$region, action:$action, component:$component,
        started_by:$started, approver:$approver, second_approver:$second, change_ticket:$ticket, reason:$reason}' > "$STATE_DIR/approval.json"
log "approval recorded: $APPROVER${SECOND_APPROVER:+ + $SECOND_APPROVER} · ticket=${CHANGE_TICKET:-n/a}"

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   why split Groovy / shell    `input` is a Jenkins step: it pauses the build and waits for a person. Everything that can be a plain script
#                               (rules, audit record) is — so it is testable on a laptop and not buried in Groovy.
#   submitterParameter          Jenkins fills APPROVER with the authenticated user who pressed Proceed; combined with `submitter:` (an
#                               allow-list of approver groups) only authorised people can approve, and the name in the record is real.
#   four-eyes                   a person who can start a prod run AND approve it alone is one account compromise away from an incident.
#   CHANGE_TICKET regex         the audit trail ties every prod change to a change request; the pattern is cheap to check, hard to fake
#                               unintentionally. (Wire it to the ticket system's API if you want to verify the ticket is APPROVED.)
#   REQUIRE_TWO                 org-wide changes (SCPs, SSO) can lock everyone out; they need two reviewers who are not the author.
#   approval.json               archived next to the plan.txt the approver saw → "who approved exactly what, when, under which ticket".
#   AUTO_APPROVE                handled in the Jenkinsfile `when` — honoured for stage only; prod and org ALWAYS reach this script.
# ════════════════════════════════════════════════════════════════════════
