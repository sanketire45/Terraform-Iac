# ════════════════════════════════════════════════════════════════════════
#  MODULE : iam-roles
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R22 [Tier A]  →  Iac_blueprint_masterclass.md, "R22"
#  Depends on : (boundary policy first)
#  Consumed by: every workload
#  Inputs  : variables below (cross-layer ones are fed by the live leaf from the SSM contract)
#  Outputs : published to SSM /<org>/<env>/iam/<key>  (see PUBLISH below the code)
#  The code is the notes' own Terraform, made self-contained; the explanation of every
#  line/argument is in the comment block at the very END of this file (copied from the notes).
# ════════════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

variable "org" {
  type        = string
  description = "Organisation prefix used in names and the SSM contract path (e.g. acme)"
}

variable "env" {
  type        = string
  description = "Environment label (dev | qa | stage | stage-dr | prod | shared | org)"
}

variable "region" {
  type        = string
  description = "Primary AWS region of this stack"
}

variable "account_id" {
  type        = string
  description = "Account alias/number used to build ARNs (e.g. the permissions-boundary ARN)"
}

variable "prefix" {
  type        = string
  description = "Naming prefix for IAM objects (e.g. the permissions boundary)"
}

variable "video_bucket" {
  type        = string
  description = "Bucket the presign role may read from"
}

# --- A service role (Lambda) with a boundary ---
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "presign" {
  name                 = "${var.prefix}-lambda-s3-presign"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = "arn:aws:iam::${var.account_id}:policy/${var.prefix}-permissions-boundary"
}
data "aws_iam_policy_document" "s3_get" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.video_bucket}/*"]
  }
}
resource "aws_iam_role_policy" "s3_get" {
  name   = "S3GetObject"
  role   = aws_iam_role.presign.id
  policy = data.aws_iam_policy_document.s3_get.json
}

# --- The permissions boundary itself: a ceiling, not a grant ---
data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "AllowOnlyApprovedServices"
    actions   = ["s3:*", "lambda:*", "logs:*", "sqs:*", "sns:*", "dynamodb:*", "kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
  }
  statement {
    sid       = "DenyIamEscalation"
    effect    = "Deny"
    actions   = ["iam:CreateUser", "iam:CreateAccessKey", "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}
resource "aws_iam_policy" "boundary" {
  name   = "${var.prefix}-permissions-boundary"
  policy = data.aws_iam_policy_document.boundary.json
}

# --- IRSA role (full version, with the OIDC data source) → R40 ---
# ─── Service roles other layers need (each carries the permissions boundary above) ───
# One map, one for_each: adding a role = one line. Each role's ARN is published to SSM as role_<name>_arn.
locals {
  service_roles = {
    app              = { services = ["ec2.amazonaws.com"], policies = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"] }
    ecs_exec         = { services = ["ecs-tasks.amazonaws.com"], policies = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"] }
    ecs_task         = { services = ["ecs-tasks.amazonaws.com"], policies = [] }
    firehose         = { services = ["firehose.amazonaws.com"], policies = [] }
    glue             = { services = ["glue.amazonaws.com"], policies = ["arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"] }
    iot_rule         = { services = ["iot.amazonaws.com"], policies = [] }
    lambda_exec      = { services = ["lambda.amazonaws.com"], policies = ["arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"] }
    edge             = { services = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"], policies = ["arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"] }
    transfer         = { services = ["transfer.amazonaws.com"], policies = [] }
    transfer_logging = { services = ["transfer.amazonaws.com"], policies = ["arn:aws:iam::aws:policy/service-role/AWSTransferLoggingAccess"] }
    sfn              = { services = ["states.amazonaws.com"], policies = [] }
    scheduler        = { services = ["scheduler.amazonaws.com"], policies = [] }
    backup           = { services = ["backup.amazonaws.com"], policies = ["arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"] }
    rds_monitoring   = { services = ["monitoring.rds.amazonaws.com"], policies = ["arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"] }
    replication      = { services = ["s3.amazonaws.com"], policies = [] }
    grafana          = { services = ["grafana.amazonaws.com"], policies = ["arn:aws:iam::aws:policy/service-role/AmazonGrafanaCloudWatchAccess"] }
  }
  role_policy_pairs = merge([
    for name, cfg in local.service_roles : {
      for p in cfg.policies : "${name}|${p}" => { role = name, policy = p }
    }
  ]...)
}
data "aws_iam_policy_document" "service_trust" {
  for_each = local.service_roles
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = each.value.services
    }
  }
}
resource "aws_iam_role" "service" {
  for_each             = local.service_roles
  name                 = "${var.prefix}-${var.env}-${replace(each.key, "_", "-")}"
  assume_role_policy   = data.aws_iam_policy_document.service_trust[each.key].json
  permissions_boundary = aws_iam_policy.boundary.arn
}
resource "aws_iam_role_policy_attachment" "service" {
  for_each   = local.role_policy_pairs
  role       = aws_iam_role.service[each.value.role].name
  policy_arn = each.value.policy
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/iam/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/iam"
  contract_strings = merge(
    {
      permissions_boundary_arn = aws_iam_policy.boundary.arn
    },
    merge({ for k, v in aws_iam_role.service : "role_${k}_arn" => v.arn }, { role_app_name = aws_iam_role.service["app"].name }),
  )
  contract_lists = {
  }
}
resource "aws_ssm_parameter" "contract_string" {
  for_each = local.contract_strings
  name     = "${local.ssm_prefix}/${each.key}"
  type     = "String"
  value    = each.value
}
resource "aws_ssm_parameter" "contract_list" {
  for_each = local.contract_lists
  name     = "${local.ssm_prefix}/${each.key}"
  type     = "StringList"
  value    = join(",", each.value)
}
output "contract" {
  description = "Everything this module publishes to SSM (also readable via the SSM path)"
  value       = merge(local.contract_strings, { for k, v in local.contract_lists : k => join(",", v) })
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R22 — IAM roles + policies + trust policies + permissions boundary  [A]  ✅REAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# An IAM role is an identity a service or pod *assumes* to get temporary permissions. Every
# role has two policy halves: a trust policy (*who may assume this role*) and permission
# policies (*what the role may do once assumed*). A permissions boundary is a ceiling on
# top of both — the role can never exceed it, even if its own policy says "allow everything".
#
# ── 2. Where it sits ──
# • Layer L3. Depends on: for IRSA — the EKS OIDC provider (R40); otherwise nothing.
# • Consumed by: Lambda (R56), API Gateway (R54), Transfer Family (R63), pods (R40/R41), Terraform
#   exec (R2).
# • Whirlpool: ✅REAL at `top-layer-IAC/role/dev/role.yaml` (also `qa`, `stage`, `prod` — 4 env
#   folders).
#
# │ The Whirlpool org-wide rule: *every* role carries a `PermissionsBoundary` pointing at one
# │ org-defined policy. It caps what any role can ever do. (The real policy name contains a
# │ spelling slip — it must match the real name exactly or role creation fails; it is
# │ written here as `<prefix>-permissions-boundary`.)
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `aws_iam_policy_document`
#       what it does: Builds policy JSON from HCL
#       why it matters: Catches typos at plan time; no hand-written JSON
#   ▸ `data … lambda_trust`
#       what it does: The trust policy
#       why it matters: Same role as CFN's `AssumeRolePolicyDocument`
#   ▸ `permissions_boundary`
#       what it does: Boundary policy ARN
#       why it matters: Without it, the org guardrail is bypassed
#   ▸ `aws_iam_role_policy`
#       what it does: An inline policy attached to a role
#       why it matters: One resource per policy
#   ▸ `aws_iam_policy` + `…_attachment`
#       what it does: A managed, reusable policy
#       why it matters: Better when many roles share one policy
#   ▸ Boundary `Deny` on `iam:PutRolePermissionsBoundary`
#       what it does: Stops a role removing its own boundary
#       why it matters: Without it the boundary can be deleted by the role it limits
#   ▸ `actions` vs `resources`
#       what it does: What vs on-what
#       why it matters: Both must be narrow
#
# ── 7. How it connects ──
# • Consumes: (IRSA) OIDC provider ARN ← EKS (R39/R40); (service roles) nothing.
# • Produces: role ARN → Lambda `Role`, API Gateway credentials, ServiceAccount annotation
#   `eks.amazonaws.com/role-arn`.
# • `Pod → ServiceAccount (annotated) → OIDC token → STS AssumeRoleWithWebIdentity → temp creds →
#   AWS API`
# • If out of order: an IRSA role created before the cluster's OIDC provider exists fails; a Lambda
#   created before its role is ready fails with *"role cannot be assumed"* (IAM is eventually
#   consistent — retry or `depends_on`).
#
# ── 8. Must-know box ──
# • Skeleton: trust policy (principal + action + conditions) · permission policy (actions +
#   resources) · `permissions_boundary` · for IRSA: `:sub` + `:aud`.
# • Gotchas:
#   • Trust policy ≠ permission policy. "Who can assume" vs "what can it do."
#   • A role's real power = intersection of its identity policies and the boundary; an SCP caps it
#     again.
#   • Named IAM resources need `CAPABILITY_NAMED_IAM` in CFN and make replacement impossible.
#   • IRSA without a `:sub` condition = any pod can assume the role.
#   • `lambda:InvokeFunction` on `*` and `s3:*` are the common over-grants.
#   • IAM is eventually consistent — a freshly created role may not be assumable for a few seconds.
#   • Where Whirlpool had 4 `role/` env folders, QA/stage/prod copies must stay in sync by hand —
#     drift is expected.
# • CFN vs TF difference: CFN's `Capabilities` acknowledgement; CFN inline `Policies:` vs Terraform
#   separate `aws_iam_role_policy` resources.
# • Interview angle: `Iac.md` §Q-resources ("EKS→OIDC→IRSA ordering", "KMS key policy vs IAM"),
#   §Q-traps ("is an SCP a permission?").
