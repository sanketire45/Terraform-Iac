# ════════════════════════════════════════════════════════════════════════
#  MODULE : messaging-sqs-sns
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R35 [Tier B]  →  Iac_blueprint_masterclass.md, "R35"
#  Depends on : kms
#  Consumed by: event-driven apps
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

variable "kms_key_id" {
  type        = string
  description = "Kms key id — read from the SSM contract (/<org>/<env>/security/kms_key_id, published by kms)"
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.env}-orders-dlq"
  message_retention_seconds = 1209600 # 14 days — time to investigate
  kms_master_key_id         = var.kms_key_arn
}

resource "aws_sqs_queue" "orders" {
  name                       = "${var.env}-orders"
  visibility_timeout_seconds = 120 # ≥ 6× your consumer's processing time
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20 # long polling: fewer empty receives, lower cost
  kms_master_key_id          = var.kms_key_arn
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5 # after 5 failed receives → DLQ
  })
}
resource "aws_sqs_queue_redrive_allow_policy" "dlq" { # only this queue may use the DLQ
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.orders.arn]
  })
}

resource "aws_sns_topic" "events" {
  name              = "${var.env}-order-events"
  kms_master_key_id = var.kms_key_id
}
resource "aws_sns_topic_subscription" "to_orders" {
  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.orders.arn
  raw_message_delivery = true
}
data "aws_iam_policy_document" "queue" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.orders.arn]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events.arn]
    }
  }
}
resource "aws_sqs_queue_policy" "orders" {
  queue_url = aws_sqs_queue.orders.id
  policy    = data.aws_iam_policy_document.queue.json
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/data/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/data"
  contract_strings = merge(
    {
      sqs_dlq_arn = aws_sqs_queue.dlq.arn
      sqs_dlq_url = aws_sqs_queue.dlq.id
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
# EXPLAINED — R35 — SQS queue + DLQ + redrive + SNS topic + subscription + policies  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# SQS is a queue (a buffer between producer and consumer). A DLQ (dead-letter queue) catches
# messages that keep failing so one bad message cannot block everything. SNS is a fan-out topic:
# publish once, deliver to many subscribers (queues, Lambdas, email).
#
# ── 2. Where it sits ──
# L3. Depends on: KMS (optional). Consumed by: services, Lambda event-source mappings, KEDA (scale
# on queue depth).
#
# CFN type names: `AWS::SQS::Queue`, `AWS::SQS::QueuePolicy`, `AWS::SNS::Topic`,
# `AWS::SNS::Subscription`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `visibility_timeout_seconds`
#       what it does: How long a received message is hidden from others
#       why it matters: Shorter than processing time → the same message is processed twice
#   ▸ `receive_wait_time_seconds = 20`
#       what it does: Long polling
#       why it matters: Cuts cost and latency vs short polling
#   ▸ `redrive_policy.maxReceiveCount`
#       what it does: Failures before moving to the DLQ
#       why it matters: Without a DLQ, a poison message loops forever
#   ▸ `message_retention_seconds` (DLQ longer)
#       what it does: How long messages are kept
#       why it matters: The DLQ needs *longer* retention than the source so you can investigate
#   ▸ `redrive_allow_policy`
#       what it does: Who may use this DLQ
#       why it matters: Prevents unrelated queues dumping into it
#   ▸ `raw_message_delivery`
#       what it does: Skip the SNS JSON envelope
#       why it matters: Consumer gets the original payload
#   ▸ Queue policy `aws:SourceArn`
#       what it does: Only *this* topic may send
#       why it matters: An SNS→SQS subscription silently delivers nothing without a queue policy
#           allowing the topic
#
# ── 7. How it connects ──
# `producer → SNS topic → SQS queue → consumer ; failures → DLQ ; queue depth → KEDA`. If out of
# order: subscribing before the queue policy exists = messages dropped silently.
#
# ── 8. Must-know box ──
# • Skeleton: DLQ · queue (visibility timeout, long polling, `redrive_policy`) · topic ·
#   subscription · queue policy letting SNS send.
# • Gotchas: missing queue policy (silent drop); visibility timeout too short; FIFO queues need
#   `.fifo` suffix and different semantics; KMS-encrypted queues need the producer to have key
#   permissions; DLQ type must match the source (FIFO↔FIFO).
# • Interview angle: `Iac.md` §Q-resources.
