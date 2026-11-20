#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 7 · Authenticate     (NO static keys anywhere)
#  Chain : Jenkins OIDC token ──sts:AssumeRoleWithWebIdentity──▶ ci-bootstrap (TOOLING account, 1h)
#          └─ the AWS provider in every leaf then does the second hop: ──sts:AssumeRole + ExternalId──▶ terraform-exec (target account)
#  Why   : each target account trusts ONLY ci-bootstrap (+ the ExternalId). A leaf can therefore only ever touch the account its
#          own provider block names; there is no key to leak, and every session is attributable in CloudTrail by its name.
#  Env   : OIDC_TOKEN (Jenkins OpenID-Connect-Provider credential, bound as a secret)  ·  ACCOUNT_MAP_FILE (alias → 12-digit id)
#          BUILD_TAG (Jenkins)  ·  TF_VAR_external_id (via TF_SECRETS_FILE)  ·  FORCE_AUTH=true (drift job: no stack list)
#  Writes: .ci/aws.env (chmod 600, ci-bootstrap session; sourced by every later script via load_aws)
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -s "$CHANGED_FILE" ] || [ "${FORCE_AUTH:-false}" = true ] || { log "nothing to deploy — no credentials requested"; exit 0; }   # FORCE_AUTH=true: the drift job authenticates for ALL stacks
need aws jq
[ -n "${OIDC_TOKEN:-}" ] || die "OIDC_TOKEN is empty — bind the Jenkins OIDC credential to the job"
load_tf_secrets
[ -n "${TF_VAR_external_id:-}" ] || die "TF_VAR_external_id is empty — it must be in TF_SECRETS_FILE (the terraform-exec trust policy requires the ExternalId)"

tooling="$(account_id TOOLING_ACCOUNT)"
# the session name is what CloudTrail shows for every API call → "which Jenkins build did this?"
session="$(printf 'jenkins-%s' "${BUILD_TAG:-manual}" | tr -c 'A-Za-z0-9+=,.@_-' '-' | cut -c1-64)"

# make sure nothing ambient (a stale profile, an instance role) is used for the exchange
unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

creds="$(aws sts assume-role-with-web-identity \
          --role-arn "arn:aws:iam::$tooling:role/ci-bootstrap" \
          --role-session-name "$session" \
          --web-identity-token "$OIDC_TOKEN" \
          --duration-seconds 3600 --output json)" || die "OIDC → ci-bootstrap failed (check the issuer / sub / aud conditions of the role's trust policy)"

umask 077
{
  printf 'export AWS_ACCESS_KEY_ID=%s\n'     "$(printf '%s' "$creds" | jq -r .Credentials.AccessKeyId)"
  printf 'export AWS_SECRET_ACCESS_KEY=%s\n' "$(printf '%s' "$creds" | jq -r .Credentials.SecretAccessKey)"
  printf 'export AWS_SESSION_TOKEN=%s\n'     "$(printf '%s' "$creds" | jq -r .Credentials.SessionToken)"
  printf 'export AWS_DEFAULT_REGION=%s\n'    "${AWS_DEFAULT_REGION:-eu-west-1}"
} > "$STATE_DIR/aws.env"

load_aws
log "authenticated as: $(aws sts get-caller-identity --query Arn --output text | sed -E 's#:[0-9]{12}:#:<tooling>:#')"

# fail EARLY and clearly if any stack's target account does not accept us (a bad ExternalId or a missing terraform-exec role)
while IFS= read -r s; do
  [ -n "$s" ] || continue
  alias_="$(grep -hoE 'arn:aws:iam::[A-Z_]+:role/terraform-exec' "$LIVE/$s/main.tf" | head -1 | sed -E 's#arn:aws:iam::([A-Z_]+):.*#\1#')"
  echo "$alias_"
done < "$CHANGED_FILE" | sort -u | while IFS= read -r a; do
  [ -n "$a" ] || continue
  aws sts assume-role --role-arn "arn:aws:iam::$(account_id "$a"):role/terraform-exec" --role-session-name "$session" \
      --external-id "$TF_VAR_external_id" --duration-seconds 900 --query Credentials.Expiration --output text >/dev/null \
    || die "cannot assume terraform-exec in $a — check the ExternalId and that ci-oidc-roles was applied there"
  log "terraform-exec reachable in $a"
done

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   OIDC_TOKEN                 a short-lived, signed JWT minted by Jenkins for THIS build. It carries claims (iss, aud, sub). AWS checks the
#                              signature against the issuer registered in IAM (aws_iam_openid_connect_provider) and the role's trust
#                              conditions on aud + sub. Nothing secret is stored in Jenkins except the ability to mint the token.
#   assume-role-with-web-identity   the call that swaps the token for temporary credentials. It needs NO prior AWS credentials,
#                              hence the `unset AWS_*` above — we want to prove the exchange works from nothing.
#   --role-session-name        becomes part of the assumed-role ARN in CloudTrail: assumed-role/ci-bootstrap/jenkins-<BUILD_TAG>.
#                              The character set is restricted by AWS and the limit is 64, hence the tr/cut.
#                              (AssumeRoleWithWebIdentity cannot carry session tags; the session name is the attribution handle.)
#   umask 077 + chmod 600      the credentials file is readable only by the build user; it lives in .ci/ (gitignored) and dies with the
#                              workspace. Jenkins masks secret-text credentials in the console log, but these derived values are not
#                              masked — never `cat` this file.
#   the probe loop             assumes terraform-exec once per distinct target account BEFORE any plan runs. A wrong ExternalId then
#                              fails in seconds with a clear message, not 20 minutes into a plan.
#   why no second hop here     the leaf's `provider "aws" { assume_role { … external_id } }` performs it; plan/apply therefore run with
#                              the target account's permissions only inside the terraform process.
# ════════════════════════════════════════════════════════════════════════
