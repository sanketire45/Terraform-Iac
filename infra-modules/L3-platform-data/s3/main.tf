# ════════════════════════════════════════════════════════════════════════
#  MODULE : s3
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R21 [Tier A]  →  Iac_blueprint_masterclass.md, "R21"
#  Depends on : kms
#  Consumed by: everything
#  Inputs  : variables below (cross-layer ones are fed by the live leaf from the SSM contract)
#  Outputs : published to SSM /<org>/<env>/security/<key>  (see PUBLISH below the code)
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

variable "kms_key_arn" {
  type        = string
  description = "Kms key arn — read from the SSM contract (/<org>/<env>/security/kms_key_arn, published by kms)"
}

variable "purpose" {
  type        = string
  description = "Bucket purpose suffix → <org>-<env>-<purpose>"
}

variable "replica_bucket_arn" {
  type        = string
  description = "ARN of the replication destination bucket"
}

variable "replica_kms_key_arn" {
  type        = string
  description = "CMK in the destination region used to encrypt replicas"
}

variable "role_replication_arn" {
  type        = string
  description = "Role replication arn — read from the SSM contract (/<org>/<env>/iam/role_replication_arn, published by iam-roles)"
}

resource "aws_s3_bucket" "data" {
  bucket = "${var.org}-${var.env}-${var.purpose}"
  lifecycle { prevent_destroy = false }
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "data" {
  bucket = aws_s3_bucket.data.id
  rule { object_ownership = "BucketOwnerEnforced" } # ACLs disabled — policies only
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    id     = "tiering-and-expiry"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

data "aws_iam_policy_document" "data" {
  statement {
    sid       = "DenyNonTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.data.arn, "${aws_s3_bucket.data.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.data.id
  policy = data.aws_iam_policy_document.data.json
}

# Optional: cross-region replication (needs versioning on BOTH buckets)
resource "aws_s3_bucket_replication_configuration" "data" {
  depends_on = [aws_s3_bucket_versioning.data]
  bucket     = aws_s3_bucket.data.id
  role       = var.role_replication_arn
  rule {
    id     = "replicate-all"
    status = "Enabled"
    filter {}
    delete_marker_replication { status = "Enabled" }
    destination {
      bucket        = var.replica_bucket_arn
      storage_class = "STANDARD_IA"
      encryption_configuration { replica_kms_key_id = var.replica_kms_key_arn }
    }
    source_selection_criteria {
      sse_kms_encrypted_objects { status = "Enabled" }
    }
  }
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/security/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/security"
  contract_strings = merge(
    {
      data_bucket_name = aws_s3_bucket.data.bucket
      data_bucket_arn  = aws_s3_bucket.data.arn
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
# EXPLAINED — R21 — S3 bucket: the full modern set  [A]  ✅REAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# S3 stores objects. A *production* bucket is never just `aws_s3_bucket`: it needs versioning
# (undo), encryption, public-access-block (no accidental exposure), a lifecycle rule
# (cost), a policy denying non-HTTPS, and sometimes replication. Since AWS provider v4,
# each of those is its own Terraform resource.
#
# ── 2. Where it sits ──
# • Layer L3. Depends on: KMS key (R18). Consumed by: CloudFront (R58), Transfer Family (R63),
#   CloudTrail/Config (R5), flow logs (R13), the Terraform state bucket (R1), app uploads.
# • Whirlpool: ✅REAL at `usb_website.yaml` (repo root — a static-site bucket with CloudFront) and
#   the S3 bucket inside `top-layer-IAC/DST/prod/dst.yml` (the SFTP→S3→CloudFront path).
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `lifecycle { prevent_destroy }`
#       what it does: Blocks deletion
#       why it matters: Buckets with data should not be one `destroy` away from gone
#   ▸ `aws_s3_bucket_versioning`
#       what it does: Versioning as its own resource
#       why it matters: Since provider v4, `versioning {}` inside the bucket was removed
#   ▸ `…_server_side_encryption_configuration` + `bucket_key_enabled`
#       what it does: Default encryption; bucket keys cut KMS calls
#       why it matters: Large cost saving on busy buckets
#   ▸ `…_public_access_block`
#       what it does: Four public-exposure flags
#       why it matters: Belt-and-braces with the account-level block
#   ▸ `…_ownership_controls … BucketOwnerEnforced`
#       what it does: Disables ACLs entirely
#       why it matters: ACLs are legacy; this makes the policy the only access control
#   ▸ `transition` / `noncurrent_version_expiration`
#       what it does: Move to cheaper classes; expire old versions
#       why it matters: Cost control
#   ▸ `abort_incomplete_multipart_upload`
#       what it does: Cleans up abandoned uploads
#       why it matters: Invisible, billable leftovers otherwise
#   ▸ `DenyNonTLS` (`aws:SecureTransport`)
#       what it does: Rejects HTTP
#       why it matters: Baseline compliance control
#   ▸ `…_replication_configuration` + `depends_on` versioning
#       what it does: Cross-region copy
#       why it matters: Fails if versioning is not enabled first on both buckets
#
# ── 7. How it connects ──
# • Consumes: KMS key (R18) for SSE-KMS; for CloudFront access a distribution ARN (R58).
# • Produces: bucket name/ARN → CloudFront origin, Transfer Family role scope (R63), IAM policies
#   (R22).
# • `SFTP → S3 (private, versioned) ← CloudFront (OAC, signed) ← Route53 alias`
# • If out of order: a bucket policy referencing a CloudFront distribution that does not exist yet
#   is rejected — create the distribution first, or have the policy use the distribution's ARN after
#   creation (a dependency CFN resolves with `!Sub` + `DependsOn`).
#
# ── 8. Must-know box ──
# • Skeleton: `aws_s3_bucket` · versioning · SSE (KMS) · public-access-block · ownership controls ·
#   lifecycle · TLS-only policy (· replication).
# • Gotchas:
#   • Provider v4 split the bucket into many resources. Old tutorials with inline `versioning {}`
#     fail.
#   • Bucket names are global and cannot be renamed.
#   • Website endpoints are HTTP only → CloudFront for HTTPS.
#   • Replication needs versioning on both ends and does not copy existing objects by default.
#   • A bucket with objects cannot be deleted unless `force_destroy = true` (dangerous) or emptied.
#   • ✅REAL finding: the static-site policy grants `s3:*` and uses the legacy OAI — know the modern
#     fix (OAC, `s3:GetObject` only, scoped by `AWS:SourceArn`).
# • CFN vs TF difference: CFN keeps everything inside one `AWS::S3::Bucket`; Terraform splits it
#   into many linked resources. CFN needs `DeletionPolicy: Retain` on data buckets; Terraform uses
#   `prevent_destroy`.
# • Interview angle: `Iac.md` §Q-resources ("S3 provider-v4 resource split"), §Q-whirlpool.
