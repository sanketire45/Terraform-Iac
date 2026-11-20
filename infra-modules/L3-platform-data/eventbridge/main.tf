# ════════════════════════════════════════════════════════════════════════
#  MODULE : eventbridge
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R36 [Tier B]  →  Iac_blueprint_masterclass.md, "R36"
#  Depends on : iam-roles
#  Consumed by: domain events, schedules
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

variable "lambda_fulfil_arn" {
  type        = string
  description = "ARN of the \"fulfil\" Lambda targeted by the EventBridge rule"
}

variable "lambda_fulfil_name" {
  type        = string
  description = "Function name of the \"fulfil\" Lambda (for lambda:InvokeFunction permission)"
}

variable "lambda_report_arn" {
  type        = string
  description = "ARN of the \"report\" Lambda targeted by the scheduler"
}

variable "role_scheduler_arn" {
  type        = string
  description = "Role scheduler arn — read from the SSM contract (/<org>/<env>/iam/role_scheduler_arn, published by iam-roles)"
}

variable "sqs_dlq_arn" {
  type        = string
  description = "Sqs dlq arn — read from the SSM contract (/<org>/<env>/data/sqs_dlq_arn, published by messaging-sqs-sns)"
}

resource "aws_cloudwatch_event_bus" "app" { name = "${var.env}-app" }

resource "aws_cloudwatch_event_rule" "order_created" {
  name           = "order-created"
  event_bus_name = aws_cloudwatch_event_bus.app.name
  event_pattern = jsonencode({
    source        = ["app.orders"],
    "detail-type" = ["OrderCreated"]
  })
}
resource "aws_cloudwatch_event_target" "to_lambda" {
  rule           = aws_cloudwatch_event_rule.order_created.name
  event_bus_name = aws_cloudwatch_event_bus.app.name
  arn            = var.lambda_fulfil_arn
  retry_policy {
    maximum_retry_attempts       = 3
    maximum_event_age_in_seconds = 3600
  }
  dead_letter_config { arn = var.sqs_dlq_arn }
}
resource "aws_lambda_permission" "events" { # EventBridge needs permission to invoke the function
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_fulfil_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.order_created.arn
}

resource "aws_scheduler_schedule" "nightly" {
  name                         = "nightly-report"
  schedule_expression          = "cron(0 2 * * ? *)"
  schedule_expression_timezone = "Europe/Dublin"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = var.lambda_report_arn
    role_arn = var.role_scheduler_arn
  }
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R36 — EventBridge custom bus + rule + target + Scheduler  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# EventBridge routes events: something happens (an event), a rule pattern-matches it, and
# a target reacts (Lambda, SQS, Step Functions). A custom bus isolates your app's events from AWS's
# default bus. Scheduler runs things at a time or rate (cron).
#
# ── 2. Where it sits ──
# L3. Consumed by: Lambda, Step Functions, SQS.
#
# CFN type names: `AWS::Events::EventBus`, `AWS::Events::Rule`, `AWS::Scheduler::Schedule`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `event_pattern`
#       what it does: The match filter
#       why it matters: Only the fields you list are matched; arrays mean "any of"
#   ▸ `event_bus_name` (on rule and target)
#       what it does: Which bus
#       why it matters: Omit it and the rule lands on the default bus, not yours
#   ▸ `retry_policy`, `dead_letter_config`
#       what it does: Delivery retries; where failed events go
#       why it matters: Without a DLQ, undeliverable events are lost
#   ▸ `aws_lambda_permission`
#       what it does: Lets EventBridge invoke the function
#       why it matters: Missing → the rule matches but the target is never called
#   ▸ `schedule_expression_timezone`
#       what it does: Schedule timezone
#       why it matters: Scheduler supports time zones; the old CloudWatch rule schedules are UTC
#           only
#   ▸ `flexible_time_window`
#       what it does: Jitter allowed
#       why it matters: `OFF` = exact time
#
# ── 7. How it connects ──
# `producer → bus → rule → target`; targets need an invoke permission. If out of order: target
# created before the Lambda exists fails.
#
# ── 8. Must-know box ──
# • Skeleton: bus · rule (pattern) · target (arn, retry, DLQ) · permission for the target ·
#   (schedule).
# • Gotchas: rule on the wrong bus; missing `lambda_permission`; cron uses 6 fields with `?`;
#   Scheduler vs Rules timezone; events matched but not delivered need a DLQ to even know.
# • Interview angle: `Iac.md` §Q-resources.
