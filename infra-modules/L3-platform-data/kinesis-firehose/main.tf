# ════════════════════════════════════════════════════════════════════════
#  MODULE : kinesis-firehose
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R37 [Tier B]  →  Iac_blueprint_masterclass.md, "R37"
#  Depends on : s3, kms, iam-roles
#  Consumed by: telemetry ingest
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

variable "lake_bucket_arn" {
  type        = string
  description = "ARN of the data-lake bucket Firehose delivers into"
}

variable "role_firehose_arn" {
  type        = string
  description = "Role firehose arn — read from the SSM contract (/<org>/<env>/iam/role_firehose_arn, published by iam-roles)"
}

resource "aws_kinesis_stream" "events" {
  name             = "${var.env}-events"
  retention_period = 48
  stream_mode_details { stream_mode = "ON_DEMAND" } # or PROVISIONED with shard_count
  encryption_type = "KMS"
  kms_key_id      = var.kms_key_arn
}

resource "aws_kinesis_firehose_delivery_stream" "to_s3" {
  name        = "${var.env}-events-to-s3"
  destination = "extended_s3"
  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.events.arn
    role_arn           = var.role_firehose_arn
  }
  extended_s3_configuration {
    role_arn            = var.role_firehose_arn
    bucket_arn          = var.lake_bucket_arn
    prefix              = "events/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/"
    buffering_size      = 64  # MB
    buffering_interval  = 300 # seconds — whichever limit hits first
    compression_format  = "GZIP"
    kms_key_arn         = var.kms_key_arn
  }
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/data/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/data"
  contract_strings = merge(
    {
      kinesis_stream_name = aws_kinesis_stream.events.name
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
# EXPLAINED — R37 — Kinesis Data Stream + Firehose delivery stream  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# Kinesis Data Streams is an ordered, replayable stream (like Kafka-lite) for real-time data.
# Firehose is a *delivery pipe*: it batches records and writes them to S3/OpenSearch without
# you running consumers. Typical: events → Kinesis → Firehose → S3 data lake.
#
# ── 2. Where it sits ──
# L3. Depends on: S3 (R21), KMS (R18), IAM (R22). Consumed by: analytics (R29), search (R28).
#
# CFN type names: `AWS::Kinesis::Stream`, `AWS::KinesisFirehose::DeliveryStream`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `stream_mode = "ON_DEMAND"`
#       what it does: Auto-scales shards
#       why it matters: No `shard_count` to tune; costs more at steady high volume
#   ▸ `retention_period`
#       what it does: Hours records stay replayable (24 h default, up to 365 d)
#       why it matters: Longer retention = replay window = cost
#   ▸ `kinesis_source_configuration`
#       what it does: Firehose reads from the stream
#       why it matters: Without it Firehose expects direct `PutRecord`
#   ▸ `prefix` with `!{timestamp:…}`
#       what it does: Hive-style date folders
#       why it matters: Lets Athena/Glue partition and prune scans
#   ▸ `error_output_prefix`
#       what it does: Where undeliverable records go
#       why it matters: Without it failures are dropped
#   ▸ `buffering_size` / `buffering_interval`
#       what it does: Batch thresholds (first to hit wins)
#       why it matters: Latency vs file size trade-off
#   ▸ `compression_format`
#       what it does: Compress on write
#       why it matters: Cuts storage and scan cost
#
# ── 7. How it connects ──
# `producer → stream → Firehose → S3 (partitioned) → Glue/Athena (R29)`. If out of order: the
# Firehose role needs S3 and Kinesis and KMS permissions before the stream is created.
#
# ── 8. Must-know box ──
# • Skeleton: stream (mode, retention, KMS) · Firehose (source, S3 destination, prefix, buffering,
#   compression, error prefix) · role.
# • Gotchas: Firehose is buffered (not real-time — up to 5 minutes); shards are ordering/throughput
#   units (hot key = hot shard); the role permissions are the usual failure; `prefix` expressions
#   are evaluated by Firehose, not Terraform (hence `!{…}`).
# • Interview angle: `Iac.md` §Q-resources.
