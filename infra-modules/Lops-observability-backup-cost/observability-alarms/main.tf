# ════════════════════════════════════════════════════════════════════════
#  MODULE : observability-alarms
#  Layer  : Lops-observability-backup-cost          Pipeline : pipeline-platform
#  Resource blueprint R64 [Tier A]  →  Iac_blueprint_masterclass.md, "R64"
#  Depends on : (every layer's resources)
#  Consumed by: on-call
#  Inputs  : variables below (cross-layer ones are fed by the live leaf from the SSM contract)
#  Outputs : published to SSM /<org>/<env>/ops/<key>  (see PUBLISH below the code)
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

variable "sns_pager_arn" {
  type        = string
  description = "SNS topic that pages the on-call"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.org}/${var.env}/orders-api"
  retention_in_days = var.env == "prod" ? 400 : 30 # ALWAYS set this
  kms_key_id        = var.kms_key_arn              # the key policy must allow logs.<region>.amazonaws.com
  log_group_class   = "STANDARD"                   # INFREQUENT_ACCESS is cheaper for audit logs
}

resource "aws_cloudwatch_log_metric_filter" "errors" {
  name           = "orders-5xx"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.status >= 500 }" # JSON log filter
  metric_transformation {
    name          = "Orders5xx"
    namespace     = "Acme/Orders"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_sns_topic" "alerts" { name = "${var.env}-alerts" }

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${var.env}-orders-5xx-high"
  namespace           = "Acme/Orders"
  metric_name         = "Orders5xx"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3 # 3 of the last 5 minutes → fewer flapping pages
  threshold           = 20
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching" # silence = healthy, not an alarm
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "latency" {

  alarm_name          = "${var.env}-orders-latency-p99"
  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  dimensions          = { ApiName = "prod-api-gateway" }
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 2000
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_composite_alarm" "orders_unhealthy" { # page only when BOTH are bad
  alarm_name    = "${var.env}-orders-unhealthy"
  alarm_rule    = "ALARM(${aws_cloudwatch_metric_alarm.errors.alarm_name}) AND ALARM(${aws_cloudwatch_metric_alarm.latency.alarm_name})"
  alarm_actions = [var.sns_pager_arn]
}

resource "aws_cloudwatch_dashboard" "orders" {
  dashboard_name = "${var.env}-orders"
  dashboard_body = jsonencode({ widgets = [{

    type   = "metric",
    x      = 0,
    y      = 0,
    width  = 12,
    height = 6,
    properties = {
      title   = "5xx",
      region  = var.region,
      stat    = "Sum",
      period  = 60,
      metrics = [["Acme/Orders", "Orders5xx"]]
    }
  }] })
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/ops/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/ops"
  contract_strings = merge(
    {
      sns_alerts_arn = aws_sns_topic.alerts.arn
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
# EXPLAINED — R64 — CloudWatch log group + metric filter + alarm + composite alarm + dashboard  [A]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# CloudWatch stores logs and metrics. A log group is a bucket of log streams. The silent
# cost bomb: a log group created with no retention keeps everything forever. A metric
# filter turns a log pattern into a metric; an alarm watches a metric; a composite alarm
# combines alarms (to cut alert noise); a dashboard is a saved view.
#
# ── 2. Where it sits ──
# L-ops, but created before the things that log to it (Lambda, EKS, API GW). Depends on: KMS (R18),
# SNS topic (R35). Consumed by: everything that logs; on-call.
#
# CFN type names: `AWS::Logs::LogGroup`, `AWS::Logs::MetricFilter`, `AWS::CloudWatch::Alarm`,
# `AWS::CloudWatch::CompositeAlarm`, `AWS::CloudWatch::Dashboard`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `retention_in_days`
#       what it does: Auto-delete old logs
#       why it matters: Omit it and logs live forever — the cost bomb. Applies to the log groups
#           EKS/Lambda/API Gateway auto-create, too, if you don't pre-create them
#   ▸ `kms_key_id`
#       what it does: Encrypt logs with your CMK
#       why it matters: The key policy must allow the CloudWatch Logs service principal or creation
#           fails
#   ▸ `pattern`
#       what it does: Filter syntax (JSON `{ $.status >= 500 }` or text)
#       why it matters: Different syntax from CloudWatch Insights
#   ▸ `metric_transformation`
#       what it does: Counts matching lines
#       why it matters: `default_value = "0"` makes "no matches" a real zero
#   ▸ `evaluation_periods` + `datapoints_to_alarm`
#       what it does: "M out of N"
#       why it matters: Reduces flapping; single-datapoint alarms page on blips
#   ▸ `treat_missing_data`
#       what it does: What no data means
#       why it matters: `notBreaching` for sparse metrics; `breaching` for heartbeat metrics
#   ▸ `extended_statistic = "p99"`
#       what it does: Percentiles
#       why it matters: `statistic` can't do p99 — use `extended_statistic`
#   ▸ `aws_cloudwatch_composite_alarm.alarm_rule`
#       what it does: Boolean over alarms
#       why it matters: Page on the combination, not each symptom
#   ▸ `alarm_actions` + `ok_actions`
#       what it does: Notify on alarm and on recovery
#       why it matters: Recovery notices stop "is it fixed?" pings
#
# ── 7. How it connects ──
# `service logs → log group → metric filter → metric → alarm → SNS → pager/chat`. If out of order:
# pre-create the log group before the Lambda/cluster so retention applies; the KMS key must exist
# and trust Logs.
#
# ── 8. Must-know box ──
# • Skeleton: log group (`retention_in_days`, KMS) · metric filter · alarm (`period`,
#   `evaluation_periods`, `datapoints_to_alarm`, `treat_missing_data`, actions) · SNS topic ·
#   (composite alarm, dashboard).
# • Gotchas:
#   • ⚠️ A log group with no retention is an unbounded cost — pre-create the groups for Lambda, EKS
#     (`/aws/eks/<cluster>/cluster`), API Gateway.
#   • Alarm on symptoms users feel (error rate, latency), not just causes (CPU).
#   • Log-group KMS key policy must allow `logs.<region>.amazonaws.com`.
#   • Cross-account log subscriptions need a destination policy.
#   • Metric filters only see logs after they are created.
# • Interview angle: `Iac.md` §Q-resources ("a CloudWatch log group with no retention is a cost
#   bomb").
