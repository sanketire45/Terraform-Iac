# ════════════════════════════════════════════════════════════════════════
#  MODULE : ssm-fleet
#  Layer  : Lops-observability-backup-cost          Pipeline : pipeline-platform
#  Resource blueprint R67 [Tier C]  →  Iac_blueprint_masterclass.md, "R67"
#  Depends on : iam-roles, vpc-endpoints
#  Consumed by: patching / no-SSH access
#  Inputs  : variables below (cross-layer ones are fed by the live leaf from the SSM contract)
#  Outputs : nothing downstream reads from this module (no SSM keys published)
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

variable "kms_key_id" {
  type        = string
  description = "Kms key id — read from the SSM contract (/<org>/<env>/security/kms_key_id, published by kms)"
}

variable "session_log_bucket" {
  type        = string
  description = "Bucket that receives SSM Session Manager logs"
}

resource "aws_ssm_document" "session_prefs" {

  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "1.0",
    sessionType   = "Standard_Stream",
    inputs = {
      s3BucketName           = var.session_log_bucket,
      cloudWatchLogGroupName = "/ssm/sessions",
      kmsKeyId               = var.kms_key_id,
      idleSessionTimeout     = "20"
    }
  })
}
resource "aws_ssm_patch_baseline" "linux" {

  name                              = "${var.env}-al2023"
  operating_system                  = "AMAZON_LINUX_2023"
  approved_patches_compliance_level = "CRITICAL"
  approval_rule {
    approve_after_days = 7
    compliance_level   = "CRITICAL"
    patch_filter {
      key    = "CLASSIFICATION"
      values = ["Security", "Bugfix"]
    }
  }
}
resource "aws_ssm_patch_group" "linux" {
  baseline_id = aws_ssm_patch_baseline.linux.id
  patch_group = "${var.env}-linux"
}
resource "aws_ssm_maintenance_window" "patch" {
  name     = "${var.env}-patching"
  schedule = "cron(0 3 ? * SUN *)"
  duration = 3
  cutoff   = 1
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R67 — SSM fleet management  [C]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# • Skeleton: Session Manager preferences (log to S3/CloudWatch, KMS) · patch baseline · patch group
#   (tag-driven) · maintenance window + task.
# • Gotchas: instances need the SSM agent + `AmazonSSMManagedInstanceCore` role and a path to the
#   SSM endpoints (R12) — SSH-free access fails silently without them; patch groups match by tag
#   `Patch Group`.
# • CFN type names: `AWS::SSM::Document`, `AWS::SSM::PatchBaseline`, `AWS::SSM::MaintenanceWindow`.
