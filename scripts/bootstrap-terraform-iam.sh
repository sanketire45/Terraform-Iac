#!/usr/bin/env bash
# =============================================================================
#  bootstrap-terraform-iam.sh — run ONCE (and again whenever the permissions change)
# =============================================================================
#  WHY OUTSIDE THE PIPELINE:
#    The pipeline assumes terraform-exec to do its work, so the role cannot be
#    created by the pipeline itself.
#
#  WHAT THIS CREATES / UPDATES (idempotent — safe to run again):
#    Role  terraform-exec
#            trust      : only the Jenkins EC2 instance role may assume it
#            permissions: exactly what the test leaves need —
#                         messaging-sqs-sns · rds-mysql  (+ the state bucket) — no KMS permissions
#    Jenkins instance role gets ONE extra inline policy: sts:AssumeRole on terraform-exec.
#    Its existing policies (e.g. AllowAssumeJenkinsCIRole for ECR) are not touched.
#
#  RUN IT WITH: your own admin credentials (the ones from `aws configure`).
#  PREREQUISITE: scripts/bootstrap-state-backend.sh has been run (the state bucket must exist).
#  USAGE:       bash scripts/bootstrap-terraform-iam.sh
#  OPTIONAL ENV: REGION (us-east-2) · ORG (acme) · ENV_PREFIX (dev) · INSTANCE_ROLE · EXEC_ROLE
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-east-2}"
ORG="${ORG:-acme}"
ENV_PREFIX="${ENV_PREFIX:-dev}"
INSTANCE_ROLE="${INSTANCE_ROLE:-CartOps-Jenkins-Instance-Role}"
EXEC_ROLE="${EXEC_ROLE:-terraform-exec}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${ORG}-tfstate-${ACCOUNT_ID}"
INSTANCE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${INSTANCE_ROLE}"
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE}"

echo "→ Account       : ${ACCOUNT_ID}"
echo "→ Region        : ${REGION}"
echo "→ Instance role : ${INSTANCE_ROLE}"
echo "→ Exec role     : ${EXEC_ROLE}"
echo ""

aws iam get-role --role-name "${INSTANCE_ROLE}" >/dev/null 2>&1 \
  || { echo "Jenkins instance role ${INSTANCE_ROLE} not found — run bootstrap-jenkins-iam.sh from the ecom project first, or set INSTANCE_ROLE=<name>" >&2; exit 1; }

aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null \
  || { echo "State bucket ${BUCKET} not found — run scripts/bootstrap-state-backend.sh first" >&2; exit 1; }

# ── terraform-exec: trust policy ─────────────────────────────────────────────
TRUST="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "${INSTANCE_ROLE_ARN}" },
    "Action": "sts:AssumeRole"
  }]
}
JSON
)"

# ── terraform-exec: permissions ──────────────────────────────────────────────
PERMS="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StateBucketList",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketVersioning"],
      "Resource": "arn:aws:s3:::${BUCKET}"
    },
    {
      "Sid": "StateObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/*"
    },
    {
      "Sid": "SsmContract",
      "Effect": "Allow",
      "Action": [
        "ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath",
        "ssm:DeleteParameter", "ssm:DeleteParameters", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource"
      ],
      "Resource": "arn:aws:ssm:*:${ACCOUNT_ID}:parameter/${ORG}/*"
    },
    {
      "Sid": "SsmDescribe",
      "Effect": "Allow",
      "Action": "ssm:DescribeParameters",
      "Resource": "*"
    },
    {
      "Sid": "SqsLeaf",
      "Effect": "Allow",
      "Action": "sqs:*",
      "Resource": "arn:aws:sqs:*:${ACCOUNT_ID}:${ENV_PREFIX}-*"
    },
    {
      "Sid": "SqsList",
      "Effect": "Allow",
      "Action": "sqs:ListQueues",
      "Resource": "*"
    },
    {
      "Sid": "SnsLeaf",
      "Effect": "Allow",
      "Action": "sns:*",
      "Resource": "arn:aws:sns:*:${ACCOUNT_ID}:${ENV_PREFIX}-*"
    },
    {
      "Sid": "RdsLeaf",
      "Effect": "Allow",
      "Action": "rds:*",
      "Resource": "arn:aws:rds:*:${ACCOUNT_ID}:*:${ENV_PREFIX}-*"
    },
    {
      "Sid": "RdsDescribe",
      "Effect": "Allow",
      "Action": ["rds:Describe*", "rds:ListTagsForResource"],
      "Resource": "*"
    },
    {
      "Sid": "Ec2NetworkForRds",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVpcs", "ec2:DescribeVpcAttribute", "ec2:DescribeSubnets", "ec2:DescribeAvailabilityZones",
        "ec2:DescribeAccountAttributes", "ec2:DescribeNetworkInterfaces", "ec2:DescribeTags",
        "ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules",
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
        "ec2:CreateTags", "ec2:DeleteTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "RdsServiceLinkedRole",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/aws-service-role/rds.amazonaws.com/AWSServiceRoleForRDS",
      "Condition": { "StringEquals": { "iam:AWSServiceName": "rds.amazonaws.com" } }
    }
  ]
}
JSON
)"

# ── instance role: may assume terraform-exec ─────────────────────────────────
ASSUME="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Resource": "${EXEC_ROLE_ARN}"
  }]
}
JSON
)"

for doc in "${TRUST}" "${PERMS}" "${ASSUME}"; do
  printf '%s' "${doc}" | jq empty || { echo "generated policy is not valid JSON" >&2; exit 1; }
done

echo "→ Role ${EXEC_ROLE}"
if aws iam get-role --role-name "${EXEC_ROLE}" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "${EXEC_ROLE}" --policy-document "${TRUST}"
  echo "  exists — trust policy updated"
else
  aws iam create-role --role-name "${EXEC_ROLE}" \
    --assume-role-policy-document "${TRUST}" \
    --description "Assumed by the Jenkins Terraform pipeline (messaging-sqs-sns and rds-mysql test leaves)" \
    --max-session-duration 3600 >/dev/null
  echo "  created"
fi

echo "→ Permissions on ${EXEC_ROLE} (inline policy TerraformExecLeaves — replaced each run)"
aws iam put-role-policy --role-name "${EXEC_ROLE}" --policy-name "TerraformExecLeaves" --policy-document "${PERMS}"

echo "→ ${INSTANCE_ROLE} may assume ${EXEC_ROLE} (inline policy AllowAssumeTerraformExec)"
aws iam put-role-policy --role-name "${INSTANCE_ROLE}" --policy-name "AllowAssumeTerraformExec" --policy-document "${ASSUME}"

echo ""
echo "✅ Done."
echo ""
echo "   Jenkins instance role : ${INSTANCE_ROLE_ARN}"
echo "   terraform-exec        : ${EXEC_ROLE_ARN}"
echo ""
echo "Check from the Jenkins node (should print the role session ARN):"
echo "  aws sts assume-role --role-arn ${EXEC_ROLE_ARN} --role-session-name test --query AssumedRoleUser.Arn --output text"
