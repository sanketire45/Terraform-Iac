# ════════════════════════════════════════════════════════════════════════
#  MODULE : xray-tracing
#  Layer  : Lops-observability-backup-cost          Pipeline : pipeline-platform
#  Resource blueprint R66 [Tier C]  →  Iac_blueprint_masterclass.md, "R66"
#  Depends on : iam-roles
#  Consumed by: tracing
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

resource "aws_xray_sampling_rule" "orders" {

  rule_name      = "orders-api"
  priority       = 100
  version        = 1
  reservoir_size = 1    # always trace the first request each second…
  fixed_rate     = 0.05 # …then 5 % of the rest
  url_path       = "/orders/*"
  host           = "*"
  http_method    = "*"
  service_name   = "*"
  service_type   = "*"
  resource_arn   = "*"
}
data "aws_iam_policy_document" "xray" {
  statement {
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  } # X-Ray write actions cannot be resource-scoped
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R66 — X-Ray sampling rule + instrumentation permissions  [C]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# • Skeleton: sampling rule (`reservoir_size`, `fixed_rate`, match fields) · the four write actions
#   on the workload role · tracing enabled on the Lambda/API stage.
# • Gotchas: 100 % sampling is expensive; rules are matched by priority; the SDK/OTel exporter must
#   be present — IAM alone traces nothing.
# • CFN type name: `AWS::XRay::SamplingRule`.
