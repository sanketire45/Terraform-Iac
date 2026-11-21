# ════════════════════════════════════════════════════════════════════════
#  MODULE : kms
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R18 [Tier A]  →  Iac_blueprint_masterclass.md, "R18"
#  Depends on : (none - first thing in the layer)
#  Consumed by: secrets, s3, rds, msk, eks, ebs
#  Inputs  : variables below (cross-layer ones are fed by the live leaf from the SSM contract)
#  Outputs : published to SSM /<org>/<env>/security/<key>  (see PUBLISH below the code)
#  The code is the notes' own Terraform, made self-contained; the explanation of every
#  line/argument is in the comment block at the very END of this file (copied from the notes).
# ════════════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.60"
      configuration_aliases = [aws.us_east_1]
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

variable "key_admin_role_arn" {
  type        = string
  description = "Role allowed to MANAGE the KMS key (not use it)"
}

variable "key_user_role_arns" {
  type        = list(string)
  description = "Roles allowed to USE the KMS key (encrypt/decrypt)"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "key" {
  # 1) Without this, nobody (not even admins) can manage the key through IAM
  statement {
    sid       = "EnableIAMPolicies"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
  # 2) Key administrators: manage, but cannot use the key to decrypt data
  statement {
    sid = "KeyAdmins"
    actions = ["kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*", "kms:Update*",
    "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.key_admin_role_arn]
    }
  }
  # 3) Key users: use it for crypto only
  statement {
    sid       = "KeyUsers"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = var.key_user_role_arns
    }
  }
  # 4) Let AWS services use it on behalf of those same principals (grants for EBS/RDS)
  statement {
    sid       = "AllowGrants"
    actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = var.key_user_role_arns
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_kms_key" "data" {
  description              = "${var.env} data-at-rest key"
  enable_key_rotation      = true # automatic yearly rotation of key material
  rotation_period_in_days  = 365
  deletion_window_in_days  = 30
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  policy                   = data.aws_iam_policy_document.key.json
  lifecycle { prevent_destroy = false }
}
resource "aws_kms_alias" "data" {
  name          = "alias/${var.env}-data" # humans and code refer to the alias, not the ID
  target_key_id = aws_kms_key.data.key_id
}

# Multi-Region key: same key material in two regions (for cross-region replicas / DR)
resource "aws_kms_key" "mrk" {
  description         = "multi-region key"
  multi_region        = true
  enable_key_rotation = true
}
resource "aws_kms_replica_key" "mrk_replica" {
  provider        = aws.us_east_1
  description     = "replica of mrk"
  primary_key_arn = aws_kms_key.mrk.arn
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/security/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/security"
  contract_strings = merge(
    {
      kms_key_arn      = aws_kms_key.data.arn
      kms_key_id       = aws_kms_key.data.key_id
      euw1_kms_key_arn = aws_kms_key.mrk.arn
      use1_kms_key_arn = aws_kms_replica_key.mrk_replica.arn
    },
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
# EXPLAINED — R18 — KMS customer-managed key + key policy + alias + rotation  [A]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# KMS holds encryption keys you never see. A customer-managed key (CMK) is one you create
# and control, so you decide *who* may use it. S3, RDS, EBS, Secrets Manager and the Terraform
# state bucket all encrypt with a CMK. The key policy is the gate — and it works differently
# from every other AWS policy.
#
# ── 2. Where it sits ──
# • Layer L3. Depends on: nothing (account only); the principals in its policy must exist or be
#   valid ARNs.
# • Consumed by: R1 (state), R19 (secrets), R21 (S3), R24 (RDS), R30 (MSK), EBS volumes, EKS secret
#   encryption (R39).
# • Whirlpool: ❌ not in this repo (a `kms` placeholder folder only).
#
# CFN type names: `AWS::KMS::Key`, `AWS::KMS::Alias`, `AWS::KMS::ReplicaKey`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `EnableIAMPolicies` (root principal)
#       what it does: Hands day-to-day permission control to IAM
#       why it matters: A key policy without this makes the key unmanageable — the #1 KMS mistake
#   ▸ `KeyAdmins` vs `KeyUsers`
#       what it does: Separates "manage the key" from "use the key"
#       why it matters: An admin who can also decrypt breaks separation of duty
#   ▸ `kms:GenerateDataKey*`
#       what it does: Needed for envelope encryption (S3/RDS/EBS)
#       why it matters: Without it a service cannot encrypt new data
#   ▸ `kms:CreateGrant` + `kms:GrantIsForAWSResource`
#       what it does: Lets EBS/RDS create a grant to use the key
#       why it matters: Missing → EBS volume / RDS instance creation fails with a KMS error
#   ▸ `enable_key_rotation`
#       what it does: New key material each year, old kept for decrypting
#       why it matters: Automatic; no downtime; compliance checkbox
#   ▸ `deletion_window_in_days`
#       what it does: Waiting period (7–30) before a key is truly deleted
#       why it matters: Deleting a key makes everything encrypted with it permanently unreadable
#   ▸ `aws_kms_alias`
#       what it does: A friendly, swappable name
#       why it matters: Code points at `alias/…`, so you can rotate to a new key without editing
#           consumers
#   ▸ `multi_region = true` + `aws_kms_replica_key`
#       what it does: Same key ID/material in another region
#       why it matters: Without it, a secret encrypted in one region cannot be decrypted in another
#   ▸ `prevent_destroy`
#       what it does: Plan error on delete
#       why it matters: Safety net for the most dangerous resource to lose
#
# ── 7. How it connects ──
# • Produces: key ARN / alias → consumed by S3 (R21), RDS (R24), Secrets (R19), MSK (R30), EKS
#   secrets (R39), state bucket (R1).
# • `principal calls service → service calls KMS → KMS checks key policy (+ IAM) → returns data key`
# • If out of order: a service created with a key ARN that does not exist fails at create time; a
#   key policy naming a role that does not exist fails with `MalformedPolicyDocument`.
#
# ── 8. Must-know box ──
# • Skeleton: `aws_kms_key` (description, `enable_key_rotation`, policy, `deletion_window_in_days`)
#   · key policy with root + admins + users + grants · `aws_kms_alias`.
# • Gotchas:
#   • KMS is the one service where the key policy alone can authorise — IAM only helps if the key
#     policy lets it in. (Hence the `root` statement.)
#   • You cannot delete a key instantly; scheduling deletion is reversible only until the window
#     ends.
#   • Cross-account use needs both the key policy *and* an IAM policy in the other account.
#   • Keys are regional.
#   • Each API call has a cost and a throttle — use S3 bucket keys (R1/R21) to cut calls.
# • CFN vs TF difference: equivalent; CFN `KeyPolicy` is raw JSON/YAML, Terraform lets you build it
#   with `aws_iam_policy_document`. CFN deletes keys per `DeletionPolicy` — set `Retain`.
# • Interview angle: `Iac.md` §Q-resources ("KMS key policy vs IAM"), §Q-traps.
