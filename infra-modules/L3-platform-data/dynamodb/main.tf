# ════════════════════════════════════════════════════════════════════════
#  MODULE : dynamodb
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R26 [Tier A]  →  Iac_blueprint_masterclass.md, "R26"
#  Depends on : kms
#  Consumed by: apps
#  Inputs  : variables below (cross-layer ones are fed by the live leaf from the SSM contract)
#  Outputs : published to SSM /<org>/<env>/data/<key>  (see PUBLISH below the code)
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

variable "use1_kms_key_arn" {
  type        = string
  description = "Use1 kms key arn — read from the SSM contract (/<org>/<env>/security/use1_kms_key_arn, published by kms)"
}

resource "aws_dynamodb_table" "orders" {
  name         = "${var.env}-orders"
  billing_mode = "PAY_PER_REQUEST" # on-demand; or PROVISIONED + autoscaling
  hash_key     = "customer_id"     # partition key
  range_key    = "order_id"        # sort key

  attribute {
    name = "customer_id"
    type = "S"
  } # ONLY attributes used in keys/indexes are declared
  attribute {
    name = "order_id"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "created_at"
    type = "N"
  }

  global_secondary_index { # query by status, newest first
    name            = "status-created_at-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }
  local_secondary_index { # same partition key, different sort key (must be set at creation)
    name            = "customer-created_at-index"
    range_key       = "created_at"
    projection_type = "KEYS_ONLY"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
  point_in_time_recovery { enabled = true } # restore to any second in the last 35 days
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }
  deletion_protection_enabled = var.env == "prod"

  stream_enabled   = true # required for Global Tables and for change-capture
  stream_view_type = "NEW_AND_OLD_IMAGES"

  # Global Tables (v2): a replica per extra region — multi-writer
  replica {
    region_name            = "us-east-1"
    kms_key_arn            = var.use1_kms_key_arn
    point_in_time_recovery = true
  }
  replica { region_name = "ap-southeast-1" }

  lifecycle { prevent_destroy = true }
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/data/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/data"
  contract_strings = merge(
    {
      orders_table_name = aws_dynamodb_table.orders.name
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
# EXPLAINED — R26 — DynamoDB table + GSI/LSI + PITR + streams + Global Tables  [A]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# A serverless key-value/document database with single-digit-millisecond reads at any scale.
# You choose a partition key (and optional sort key); everything else is "how do I query it
# another way" — indexes — and "how do I protect and replicate it" — PITR, streams,
# Global Tables. Global Tables make it multi-region multi-writer.
#
# ── 2. Where it sits ──
# L3. Depends on: KMS (R18, optional). Consumed by: Lambda, services, Streams → Lambda/Kinesis.
#
# CFN type names: `AWS::DynamoDB::Table`, `AWS::DynamoDB::GlobalTable`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `billing_mode = "PAY_PER_REQUEST"`
#       what it does: On-demand capacity
#       why it matters: No capacity planning; costlier at steady heavy load than provisioned
#   ▸ `hash_key` / `range_key`
#       what it does: Partition key / sort key
#       why it matters: Immutable. Wrong key design = rebuild the table. A hot partition key
#           throttles you
#   ▸ `attribute {}`
#       what it does: Declares types for keys and index keys only
#       why it matters: Declaring a non-key attribute is an error; DynamoDB is schemaless otherwise
#   ▸ `global_secondary_index`
#       what it does: A second access pattern with its own keys
#       why it matters: Can be added/removed later; has its own capacity
#   ▸ `local_secondary_index`
#       what it does: Same partition key, different sort key
#       why it matters: Only at table creation; limits item-collection size to 10 GB
#   ▸ `projection_type`
#       what it does: Which attributes the index carries
#       why it matters: `ALL` is simple but doubles storage; `KEYS_ONLY` is cheapest
#   ▸ `ttl`
#       what it does: Auto-delete items past a timestamp
#       why it matters: Free deletes; not instant (can lag ~48 h)
#   ▸ `point_in_time_recovery`
#       what it does: Continuous backup, 35-day window
#       why it matters: Off by default — turn on for anything you care about
#   ▸ `server_side_encryption … kms_key_arn`
#       what it does: CMK instead of the AWS-owned key
#       why it matters: Needed for key-level control
#   ▸ `stream_enabled` + `stream_view_type`
#       what it does: Change feed of item modifications
#       why it matters: Required for Global Tables; also feeds Lambda/analytics
#   ▸ `replica {}`
#       what it does: A Global Table replica region
#       why it matters: Multi-writer, last-writer-wins conflict resolution
#   ▸ `deletion_protection_enabled`
#       what it does: API-level delete block
#       why it matters: Separate from Terraform `prevent_destroy`
#
# ── 7. How it connects ──
# `service → table`; `table stream → Lambda / Kinesis / Global replicas`. Region replicas replicate
# to each other automatically.
# If out of order: a Global Table replica needs streams enabled and compatible settings; a KMS key
# in a replica region must exist first.
#
# ── 8. Must-know box ──
# • Skeleton: name · `billing_mode` · `hash_key` (+ `range_key`) · `attribute` for key fields only ·
#   GSI · PITR · SSE · TTL · streams · `replica`.
# • Gotchas:
#   • Key schema is immutable.
#   • LSIs only at creation.
#   • Global Tables = last-writer-wins, so conflicting writes in two regions silently lose one.
#   • `attribute {}` for non-key fields causes a validation error.
#   • PITR and deletion protection are off by default.
#   • Mixing `aws_dynamodb_table` `replica {}` with the old `aws_dynamodb_global_table` resource is
#     a known trap — use one model.
# • CFN vs TF difference: CFN has a separate `AWS::DynamoDB::GlobalTable` resource; Terraform folds
#   replicas into `aws_dynamodb_table`.
# • Interview angle: `Iac.md` §Q-architecture.
