# ════════════════════════════════════════════════════════════════════════
#  MODULE : elasticache
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R27 [Tier B]  →  Iac_blueprint_masterclass.md, "R27"
#  Depends on : vpc, security-groups, kms
#  Consumed by: apps
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

variable "kms_key_arn" {
  type        = string
  description = "Kms key arn — read from the SSM contract (/<org>/<env>/security/kms_key_arn, published by kms)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

variable "redis_auth_token" {
  type        = string
  description = "Redis AUTH token (injected by the pipeline, never in git)"
  sensitive   = true
}

variable "sg_cache_id" {
  type        = string
  description = "Sg cache id — read from the SSM contract (/<org>/<env>/network/sg_cache_id, published by security-groups)"
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.env}-cache"
  subnet_ids = var.private_subnet_ids
}
resource "aws_elasticache_replication_group" "this" {
  replication_group_id       = "${var.env}-sessions"
  description                = "Session cache"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = var.env == "prod" ? "cache.r7g.large" : "cache.t4g.small"
  num_cache_clusters         = var.env == "prod" ? 3 : 1 # primary + replicas
  automatic_failover_enabled = var.env == "prod"
  multi_az_enabled           = var.env == "prod"
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [var.sg_cache_id]
  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  transit_encryption_enabled = true
  auth_token                 = var.redis_auth_token # ⚠️ ends up in state — see gotchas
  snapshot_retention_limit   = var.env == "prod" ? 7 : 0
  maintenance_window         = "sun:03:00-sun:04:00"
  apply_immediately          = false
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R27 — ElastiCache replication group  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# Managed Redis/Valkey: an in-memory cache. A replication group = one primary + replicas
# across AZs with automatic failover, used for caching, sessions, rate limiting.
#
# ── 2. Where it sits ──
# L3. Depends on: VPC, private subnets, SG (R10), KMS (R18). Consumed by: services.
#
# CFN type names: `AWS::ElastiCache::ReplicationGroup`, `AWS::ElastiCache::SubnetGroup`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `num_cache_clusters`
#       what it does: Primary + N−1 replicas
#       why it matters: Failover needs at least 2
#   ▸ `automatic_failover_enabled` + `multi_az_enabled`
#       what it does: Promote a replica if the primary dies
#       why it matters: Without it, a primary failure is an outage
#   ▸ `at_rest_encryption_enabled` / `transit_encryption_enabled`
#       what it does: Encrypt on disk / on the wire
#       why it matters: Cannot be changed later on an existing group
#   ▸ `auth_token`
#       what it does: Redis password (requires transit encryption)
#       why it matters: Lands in state — rotate via Secrets Manager
#   ▸ `snapshot_retention_limit`
#       what it does: Daily backups to keep
#       why it matters: `0` = no backups (fine for a pure cache)
#   ▸ `apply_immediately`
#       what it does: Apply now vs maintenance window
#       why it matters: `true` may trigger a failover
#
# ── 7. How it connects ──
# `app → (SG from app SG, port 6379) → primary endpoint / reader endpoint`; endpoint published to
# SSM (R20).
#
# ── 8. Must-know box ──
# • Skeleton: subnet group · replication group (engine/version/node type, `num_cache_clusters`,
#   failover + multi-AZ, encryption at rest + in transit, SG).
# • Gotchas: encryption settings are create-time only; use the primary endpoint for writes and the
#   reader endpoint for reads; a cache is not a database — losing it must be survivable; node-type
#   change = replacement of nodes (brief failover).
# • Interview angle: `Iac.md` §Q-resources.
