# ════════════════════════════════════════════════════════════════════════
#  MODULE : aurora-global
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R25 [Tier B]  →  Iac_blueprint_masterclass.md, "R25"
#  Depends on : rds-aurora (primary region)
#  Consumed by: DR tier 0/1
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
      configuration_aliases = [aws.euw1, aws.use1]
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

variable "euw1_kms_key_arn" {
  type        = string
  description = "Euw1 kms key arn — read from the SSM contract (/<org>/<env>/security/euw1_kms_key_arn, published by kms)"
}

variable "euw1_subnet_group" {
  type        = string
  description = "DB subnet group in the primary region (us-east-2)"
}

variable "use1_kms_key_arn" {
  type        = string
  description = "Use1 kms key arn — read from the SSM contract (/<org>/<env>/security/use1_kms_key_arn, published by kms)"
}

variable "use1_subnet_group" {
  type        = string
  description = "DB subnet group in the secondary region (us-east-1)"
}

resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier = "orders-global"
  engine                    = "aurora-postgresql"
  engine_version            = "15.4"
  storage_encrypted         = true
  deletion_protection       = true
}

# PRIMARY (us-east-2)
resource "aws_rds_cluster" "primary" {
  provider                    = aws.euw1
  cluster_identifier          = "orders-euw1"
  global_cluster_identifier   = aws_rds_global_cluster.this.id
  engine                      = aws_rds_global_cluster.this.engine
  engine_version              = aws_rds_global_cluster.this.engine_version
  master_username             = "dbadmin"
  manage_master_user_password = true
  db_subnet_group_name        = var.euw1_subnet_group
  storage_encrypted           = true
  kms_key_id                  = var.euw1_kms_key_arn
}
resource "aws_rds_cluster_instance" "primary" {
  provider           = aws.euw1
  identifier         = "orders-euw1-0"
  cluster_identifier = aws_rds_cluster.primary.id
  instance_class     = "db.r6g.large"
  engine             = aws_rds_cluster.primary.engine
  engine_version     = aws_rds_cluster.primary.engine_version
}

# SECONDARY (us-east-1) — read-only until promoted
resource "aws_rds_cluster" "secondary" {
  provider                  = aws.use1
  cluster_identifier        = "orders-use1"
  global_cluster_identifier = aws_rds_global_cluster.this.id
  engine                    = aws_rds_global_cluster.this.engine
  engine_version            = aws_rds_global_cluster.this.engine_version
  db_subnet_group_name      = var.use1_subnet_group
  storage_encrypted         = true
  kms_key_id                = var.use1_kms_key_arn # a DIFFERENT regional key
  skip_final_snapshot       = true
  depends_on                = [aws_rds_cluster_instance.primary] # primary must exist first
  lifecycle { ignore_changes = [replication_source_identifier] }
}
resource "aws_rds_cluster_instance" "secondary" {
  provider           = aws.use1
  identifier         = "orders-use1-0"
  cluster_identifier = aws_rds_cluster.secondary.id
  instance_class     = "db.r6g.large"
  engine             = aws_rds_cluster.secondary.engine
  engine_version     = aws_rds_cluster.secondary.engine_version
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R25 — Aurora Global Database  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# One writer region plus up to five read-only secondary regions, replicated by storage
# (typically < 1 s lag). For DR you can promote a secondary to take writes. It is the
# "one writer, many readers across regions" answer; if you need writes in many regions, you want
# DynamoDB Global Tables (R26) or geo-partitioned databases instead.
#
# ── 2. Where it sits ──
# L3. Depends on: R24 in the primary region, VPC/KMS in the secondary region. Consumed by: DR
# runbooks.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `aws_rds_global_cluster`
#       what it does: The logical wrapper spanning regions
#       why it matters: Holds the engine/version both sides must share
#   ▸ `global_cluster_identifier` on each cluster
#       what it does: Joins a regional cluster to the global one
#       why it matters: Without it they are two unrelated databases
#   ▸ `provider = aws.use1`
#       what it does: Builds the secondary in another region
#       why it matters: Resources are regional; you need a provider alias
#   ▸ Secondary has no `master_username`
#       what it does: Credentials replicate from the primary
#       why it matters: Setting them on a secondary conflicts
#   ▸ `kms_key_id` per side
#       what it does: Each region uses its own key
#       why it matters: A key in one region cannot be used in another (R18)
#   ▸ `depends_on` the primary instance
#       what it does: Secondary attaches to a *running* primary
#       why it matters: Out-of-order creation fails
#   ▸ `ignore_changes = [replication_source_identifier]`
#       what it does: Allows promotion without Terraform trying to undo it
#       why it matters: After failover the roles swap; Terraform must not fight it
#
# ── 7. How it connects ──
# `primary writer ──storage replication──► secondary readers`; on failover: promote the secondary
# (`failover-global-cluster`), re-point apps/Route53 (R16). If out of order: secondary before
# primary exists = failure.
#
# ── 8. Must-know box ──
# • Skeleton: `aws_rds_global_cluster` · primary cluster + instance · secondary cluster
#   (`global_cluster_identifier`, own KMS key) + instance.
# • Gotchas: one writer only; after a failover Terraform's idea of "primary" is wrong — plan the
#   state handling; managed failover vs manual promotion; replication lag during heavy writes;
#   per-region KMS keys.
# • Interview angle: `Iac.md` §Q-architecture, §Q-whirlpool ("DR design").
