#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  STAGE 7 · Authenticate     (Whirlpool style: config file → ONE sts assume-role per environment)
#
#  Whirlpool (lib/commonInfraFunctions.groovy → awsAuthentication):
#      config_file = "config/${ENV_STAGE}-config.txt"
#      account_id  = readConfigParameter("AWS_ACCOUNT_ID", config_file)
#      role        = grep JENKINS_ROLE_ARN= config_file
#      aws sts assume-role --role-arn arn:aws:iam::<account_id>:role/<role> --role-session-name jenkins
#      → AccessKeyId / SecretAccessKey / SessionToken saved into an AWS CLI profile
#  Here (same idea, same four steps):
#      config file  : pipelines/config/<scope>-config.txt            (scope = dev | qa | stage | prod | _shared)
#      account/role : AWS_ACCOUNT_ID and JENKINS_ROLE_ARN from that file
#      assume-role  : the Jenkins AGENT's own AWS identity (instance role / profile on the node) calls sts:AssumeRole
#      saved to     : .ci/aws-<scope>.env  (chmod 600) — Terraform reads the variables, so no CLI profile is needed
#
#  Reads : .ci/changed_stacks.txt · pipelines/config/<scope>-config.txt
#  Writes: .ci/aws-<scope>.env, one per distinct scope in the stack list (a PR build can touch several; a normal run has one)
#  Env   : BUILD_TAG (Jenkins, used in the session name) · FORCE_AUTH=true (drift job: no stack list)
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -s "$CHANGED_FILE" ] || [ "${FORCE_AUTH:-false}" = true ] || { log "nothing to deploy — no credentials requested"; exit 0; }
need aws jq

# 0. who is Jenkins right now?  (Whirlpool relies on this too: the agent must already have an AWS identity)
me="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)" \
  || die "the Jenkins agent has no AWS identity — give the node an instance role / profile / keys that may call sts:AssumeRole on the role named in JENKINS_ROLE_ARN"
log "Jenkins agent identity: $(printf '%s' "$me" | sed -E 's#:[0-9]{12}:#:<account>:#')"

session="$(printf 'jenkins-%s' "${BUILD_TAG:-manual}" | tr -c 'A-Za-z0-9+=,.@_-' '-' | cut -c1-64)"   # shows up in CloudTrail

# 1. which environments (scopes) do the changed stacks belong to?   L3-platform-data/<dev>/eu-west-1/kms → dev
if [ -s "$CHANGED_FILE" ]; then scopes="$(cut -d/ -f2 "$CHANGED_FILE" | sort -u)"; else scopes="${TARGET_ENV:?}"; fi

# 2. for each scope: read its config file, assume the role in that account, save the session
for scope in $scopes; do
  cfg="$(config_file "$scope")"
  if [ "$scope" = "${TARGET_ENV:-}" ] && [ -n "${AWS_ACCOUNT_ID:-}" ]; then
    account="$AWS_ACCOUNT_ID"; role="$JENKINS_ROLE_ARN"; region="$AWS_REGION"
  else
    account="$(read_config AWS_ACCOUNT_ID   "$cfg")"
    role="$(read_config    JENKINS_ROLE_ARN "$cfg")"
    region="$(read_config  AWS_REGION       "$cfg")"
  fi
  for pair in "AWS_ACCOUNT_ID=$account" "JENKINS_ROLE_ARN=$role" "AWS_REGION=$region"; do
    case "${pair#*=}" in ''|REPLACE*) die "${pair%%=*} is not filled in: ${cfg#$ROOT/}" ;; esac
  done

  # (Whirlpool: ASSUMED_ROLE=`aws sts assume-role --role-arn arn:aws:iam::${account_id}:role/${roletoassume} --role-session-name jenkins`)
  creds="$(aws sts assume-role \
            --role-arn "arn:aws:iam::$account:role/$role" \
            --role-session-name "$session" \
            --duration-seconds 3600 --output json)" \
    || die "cannot assume role/$role in the '$scope' account — does the role's trust policy allow the Jenkins agent identity above?"

  # (Whirlpool: python one-liners pick the three values, then `aws configure set … --profile`)
  umask 077
  {
    printf 'export AWS_ACCESS_KEY_ID=%s\n'     "$(printf '%s' "$creds" | jq -r .Credentials.AccessKeyId)"
    printf 'export AWS_SECRET_ACCESS_KEY=%s\n' "$(printf '%s' "$creds" | jq -r .Credentials.SecretAccessKey)"
    printf 'export AWS_SESSION_TOKEN=%s\n'     "$(printf '%s' "$creds" | jq -r .Credentials.SessionToken)"
    printf 'export AWS_DEFAULT_REGION=%s\n'    "$region"
  } > "$STATE_DIR/aws-$scope.env"

  # prove the saved session works and really is the target account (a wrong account id in the config file fails HERE, in seconds)
  ( . "$STATE_DIR/aws-$scope.env"
    got="$(aws sts get-caller-identity --query Account --output text)" || exit 1
    [ "$got" = "$account" ] || { echo "session is in a different account than AWS_ACCOUNT_ID" >&2; exit 1; } ) \
    || die "the '$scope' session does not work or is not in AWS_ACCOUNT_ID — check ${cfg#$ROOT/}"
  log "scope '$scope': assumed role/$role (account from ${cfg#$ROOT/}) → .ci/aws-$scope.env"
done

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   config file per scope      same idea as Whirlpool's config/${ENV_STAGE}-config.txt: the values that differ per environment live in a
#                              small KEY=value file, never in the scripts. read_config (lib.sh) = their readConfigParameter (grep KEY= | sed).
#   the agent's own identity   `aws sts assume-role` with NO token and NO keys given: the AWS CLI uses whatever the node already has
#                              (instance profile, a profile, env keys). That is Whirlpool's model; step 0 above prints it so you can see it.
#   --role-session-name        Whirlpool uses the constant "jenkins"; we add BUILD_TAG so CloudTrail shows WHICH build made each call.
#   --duration-seconds 3600    one hour. Plan + approval wait + apply must finish inside it (a longer approval needs a fresh Authenticate).
#   .ci/aws-<scope>.env        what Whirlpool does with `aws configure set … --profile`, but as plain `export` lines. lib.sh `load_aws <stack>`
#                              sources the file of that stack's scope; `exec_env <stack>` prints it for the AWS-CLI smoke tests.
#   umask 077                  the file is readable only by the build user; cleanup.sh deletes it at the end of every build.
#   one hop only               the leaves' provider blocks have NO assume_role any more: Terraform simply uses the exported session, so
#                              plan/apply act with the permissions of role/JENKINS_ROLE_ARN in that account. The state bucket lives in
#                              SHARED_ACCOUNT_ID, so its bucket + KMS key policies must allow these roles (one policy statement per env role).
# ════════════════════════════════════════════════════════════════════════
