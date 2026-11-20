# ════════════════════════════════════════════════════════════════════════
#  MODULE : analytics
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R29 [Tier C]  →  Iac_blueprint_masterclass.md, "R29"
#  Depends on : s3, kms
#  Consumed by: BI / data lake
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

variable "athena_results_bucket" {
  type        = string
  description = "S3 bucket where Athena writes query results"
}

variable "kms_key_arn" {
  type        = string
  description = "Kms key arn — read from the SSM contract (/<org>/<env>/security/kms_key_arn, published by kms)"
}

variable "log_bucket" {
  type        = string
  description = "Bucket that receives access / flow logs"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

variable "role_glue_arn" {
  type        = string
  description = "Role glue arn — read from the SSM contract (/<org>/<env>/iam/role_glue_arn, published by iam-roles)"
}

variable "sg_redshift_id" {
  type        = string
  description = "Sg redshift id — read from the SSM contract (/<org>/<env>/network/sg_redshift_id, published by security-groups)"
}

resource "aws_redshift_subnet_group" "this" {
  name       = "${var.env}-rs"
  subnet_ids = var.private_subnet_ids
}
resource "aws_redshift_cluster" "this" {
  cluster_identifier        = "${var.env}-warehouse"
  node_type                 = "ra3.xlplus"
  number_of_nodes           = 2
  database_name             = "analytics"
  master_username           = "admin"
  manage_master_password    = true # Secrets Manager-managed
  cluster_subnet_group_name = aws_redshift_subnet_group.this.name
  vpc_security_group_ids    = [var.sg_redshift_id]
  encrypted                 = true
  kms_key_id                = var.kms_key_arn
  publicly_accessible       = false
  skip_final_snapshot       = var.env != "prod"
  enhanced_vpc_routing      = true
}

resource "aws_athena_workgroup" "this" {
  name = "${var.env}-analytics"
  configuration {
    enforce_workgroup_configuration = true
    result_configuration {
      output_location = "s3://${var.athena_results_bucket}/results/"
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }
    bytes_scanned_cutoff_per_query = 10737418240 # 10 GB cap per query — a cost brake
  }
}

resource "aws_glue_catalog_database" "this" { name = "${var.env}_analytics" }
resource "aws_glue_crawler" "flow_logs" {
  name          = "${var.env}-flowlogs"
  database_name = aws_glue_catalog_database.this.name
  role          = var.role_glue_arn
  s3_target { path = "s3://${var.log_bucket}/vpc-flow/" }
  schedule = "cron(0 3 * * ? *)"
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R29 — Analytics tier: Redshift + Athena + Glue  [C]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# • Skeleton: Redshift cluster (`manage_master_password`, encrypted, not public) · Athena workgroup
#   (enforced config, results location, scan cap) · Glue DB + crawler.
# • Gotchas: `publicly_accessible = false`; Athena has no server — you pay per data scanned →
#   Parquet + partitions + the `bytes_scanned_cutoff`; the Glue crawler needs an IAM role with S3 +
#   Glue access; Redshift pauses are not automatic.
# • CFN type names: `AWS::Redshift::Cluster`, `AWS::Athena::WorkGroup`, `AWS::Glue::Database`,
#   `AWS::Glue::Crawler`.
