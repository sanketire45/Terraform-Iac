# ════════════════════════════════════════════════════════════════════════
#  MODULE : backup
#  Layer  : Lops-observability-backup-cost          Pipeline : pipeline-platform
#  Resource blueprint R68 [Tier B]  →  Iac_blueprint_masterclass.md, "R68"
#  Depends on : kms
#  Consumed by: all stateful data
#  Inputs  : variables below (cross-layer ones are fed by the live leaf from the SSM contract)
#  Outputs : nothing downstream reads from this module (no SSM keys published)
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

variable "kms_key_arn" {
  type        = string
  description = "Kms key arn — read from the SSM contract (/<org>/<env>/security/kms_key_arn, published by kms)"
}

variable "role_backup_arn" {
  type        = string
  description = "Role backup arn — read from the SSM contract (/<org>/<env>/iam/role_backup_arn, published by iam-roles)"
}

variable "use1_kms_key_arn" {
  type        = string
  description = "Use1 kms key arn — read from the SSM contract (/<org>/<env>/security/use1_kms_key_arn, published by kms)"
}

resource "aws_backup_vault" "primary" {
  name        = "${var.env}-vault"
  kms_key_arn = var.kms_key_arn
}
resource "aws_backup_vault_lock_configuration" "primary" {
  backup_vault_name   = aws_backup_vault.primary.name
  min_retention_days  = 7
  max_retention_days  = 400
  changeable_for_days = 3 # grace period; after it the lock is PERMANENT
}
resource "aws_backup_vault" "dr" {
  provider    = aws.us_east_1
  name        = "${var.env}-vault-dr"
  kms_key_arn = var.use1_kms_key_arn
}

resource "aws_backup_plan" "daily" {
  name = "${var.env}-daily"
  rule {
    rule_name         = "daily-35d"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = "cron(0 2 * * ? *)"
    lifecycle { delete_after = 35 }
    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn
      lifecycle { delete_after = 35 }
    } # cross-region copy
  }
}
resource "aws_backup_selection" "tagged" {
  name         = "tagged-backup-daily"
  plan_id      = aws_backup_plan.daily.id
  iam_role_arn = var.role_backup_arn
  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Backup"
    value = "daily"
  } # tag a resource → it is protected
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R68 — AWS Backup: plan + vault + vault lock + selection + cross-region copy  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# AWS Backup is one place to schedule backups for RDS, DynamoDB, EFS, EBS and more. A vault holds
# recovery points; vault lock makes them immutable (even for admins — ransomware defence);
# tag-based selection means a new resource is protected just by being tagged.
#
# ── 2. Where it sits ──
# L-ops. Depends on: KMS (R18), an IAM role, the resources being backed up. Consumed by: DR runbooks
# (§2.7).
#
# CFN type names: `AWS::Backup::BackupPlan`, `AWS::Backup::BackupVault`,
# `AWS::Backup::BackupSelection`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `aws_backup_vault_lock_configuration`
#       what it does: Makes recovery points immutable
#       why it matters: `changeable_for_days` = a grace window; afterwards the lock cannot be
#           removed by anyone, including root — test first
#   ▸ `min/max_retention_days`
#       what it does: Allowed retention range
#       why it matters: A backup rule outside it is rejected
#   ▸ `schedule`
#       what it does: Cron
#       why it matters: Stagger heavy services
#   ▸ `lifecycle.delete_after`
#       what it does: Expire recovery points
#       why it matters: Control cost
#   ▸ `copy_action`
#       what it does: Copy to another vault/region/account
#       why it matters: DR needs data outside the failing region
#   ▸ `selection_tag`
#       what it does: Tag-based membership
#       why it matters: New resources are covered automatically — and untagged ones are silently not
#           backed up
#   ▸ `iam_role_arn`
#       what it does: The role AWS Backup uses
#       why it matters: Needs the AWS-managed backup + restore policies
#
# ── 7. How it connects ──
# `tagged resources → plan → vault → (copy) → DR-region vault`; restores create new resources. If
# out of order: the DR vault/key must exist first; a lock on the wrong vault is permanent.
#
# ── 8. Must-know box ──
# • Skeleton: vault (+ KMS) · vault lock · plan (schedule, lifecycle, `copy_action`) · selection
#   (tags + role).
# • Gotchas: untagged = unprotected; vault lock is irreversible after the grace period; KMS keys are
#   regional so the DR vault needs its own key; a backup you have never restored is a hope, not a
#   backup.
# • Interview angle: `Iac.md` §Q-operations.
