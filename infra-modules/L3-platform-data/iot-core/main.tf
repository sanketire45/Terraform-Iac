# ════════════════════════════════════════════════════════════════════════
#  MODULE : iot-core
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R38 [Tier B]  →  Iac_blueprint_masterclass.md, "R38"
#  Depends on : iam-roles, msk|kinesis
#  Consumed by: device ingest (scope 🟡 confirm)
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

variable "account_id" {
  type        = string
  description = "Account alias/number used to build ARNs (e.g. the permissions-boundary ARN)"
}

variable "kinesis_stream_name" {
  type        = string
  description = "Kinesis stream name — read from the SSM contract (/<org>/<env>/data/kinesis_stream_name, published by kinesis-firehose)"
}

variable "role_iot_rule_arn" {
  type        = string
  description = "Role iot rule arn — read from the SSM contract (/<org>/<env>/iam/role_iot_rule_arn, published by iam-roles)"
}

variable "sqs_dlq_url" {
  type        = string
  description = "Sqs dlq url — read from the SSM contract (/<org>/<env>/data/sqs_dlq_url, published by messaging-sqs-sns)"
}

resource "aws_iot_thing_type" "appliance" { name = "${var.env}-appliance" }

resource "aws_iot_policy" "device" {
  name = "${var.env}-device-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow",
        Action   = "iot:Connect",
        Resource = "arn:aws:iot:${var.region}:${var.account_id}:client/$${iot:Connection.Thing.ThingName}"
      },
      {
        Effect   = "Allow",
        Action   = ["iot:Publish", "iot:Receive"],
        Resource = "arn:aws:iot:${var.region}:${var.account_id}:topic/devices/$${iot:Connection.Thing.ThingName}/*"
      },
      {
        Effect   = "Allow",
        Action   = "iot:Subscribe",
        Resource = "arn:aws:iot:${var.region}:${var.account_id}:topicfilter/devices/$${iot:Connection.Thing.ThingName}/*"
      }
    ]
  })
}

# One certificate per device, created and attached (the private key must be captured once — see gotchas)
resource "aws_iot_certificate" "device" { active = true }
resource "aws_iot_policy_attachment" "device" {
  policy = aws_iot_policy.device.name
  target = aws_iot_certificate.device.arn
}
resource "aws_iot_thing" "device" {
  name            = "${var.env}-device-001"
  thing_type_name = aws_iot_thing_type.appliance.name
}
resource "aws_iot_thing_principal_attachment" "device" {
  thing     = aws_iot_thing.device.name
  principal = aws_iot_certificate.device.arn
}

# Topic rule: route every telemetry message to a Kinesis/Kafka-bound pipeline
resource "aws_iot_topic_rule" "telemetry" {
  name        = "${replace(var.env, "-", "_")}_telemetry"
  enabled     = true
  sql         = "SELECT *, topic(2) AS device_id FROM 'devices/+/telemetry'"
  sql_version = "2016-03-23"
  kinesis {
    stream_name   = var.kinesis_stream_name
    role_arn      = var.role_iot_rule_arn
    partition_key = "$${topic(2)}"
  }
  error_action {
    sqs {
      use_base64 = false # required by the provider: send the raw message
      queue_url  = var.sqs_dlq_url
      role_arn   = var.role_iot_rule_arn
    }
  }
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R38 — AWS IoT Core: thing type, policy, certificate attachment, topic rule  [B]  🧪IDEAL · 🟡CONFIRM scope
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# IoT Core is the managed MQTT front door for devices. Each device has a thing (its record),
# a certificate (its identity), and a policy (what topics it may publish/subscribe to). A
# topic rule then routes incoming messages to AWS services — here, to MSK/Kafka, SQS or Lambda.
#
# ── 2. Where it sits ──
# L3. Consumed by: MSK (R30), Lambda (R56), Kinesis (R37).
# │ 🟡CONFIRM: this was an IoT shared-services platform with MQTT pipelines (devices → IoT Core → MSK
# │ → consumers), but the IoT Core resources themselves are not in this repo. Treat this block as
# │ the standard pattern, not as something you wrote.
#
# CFN type names: `AWS::IoT::ThingType`, `AWS::IoT::Policy`, `AWS::IoT::Certificate`,
# `AWS::IoT::Thing`, `AWS::IoT::TopicRule`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `$${iot:Connection.Thing.ThingName}`
#       what it does: Policy variable: the connecting device's own name
#       why it matters: One policy serves every device — each can only touch *its own* topics. `$$`
#           escapes Terraform's own `${}`
#   ▸ `iot:Connect` / `Publish` / `Receive` / `Subscribe`
#       what it does: The four MQTT permissions
#       why it matters: Receive and Subscribe need different resource types (`topic` vs
#           `topicfilter`)
#   ▸ `aws_iot_certificate.active`
#       what it does: Whether the cert may connect
#       why it matters: Revoke by setting `false`
#   ▸ `aws_iot_policy_attachment`
#       what it does: Binds policy to the certificate
#       why it matters: Policies attach to certs, not to things
#   ▸ `aws_iot_thing_principal_attachment`
#       what it does: Binds the cert to the thing
#       why it matters: Links identity to the record
#   ▸ `sql` with `topic(2)`
#       what it does: Rule query: pick the 2nd topic segment
#       why it matters: Extracts the device ID for routing
#   ▸ `error_action`
#       what it does: Where failed rule actions go
#       why it matters: Without it, failures vanish
#
# ── 7. How it connects ──
# `device (MQTT/TLS, cert) → IoT Core → policy check → topic rule → Kinesis/Kafka/Lambda`. If out of
# order: the rule's role must be able to write to the target before the rule is created.
#
# ── 8. Must-know box ──
# • Skeleton: thing type · policy (with policy variables) · certificate · policy→cert attachment ·
#   thing→cert attachment · topic rule (SQL + action + error action).
# • Gotchas: ⚠️ `aws_iot_certificate` returns the private key into Terraform state — for real
#   fleets, use *just-in-time provisioning* / fleet provisioning instead; policy variables are the
#   scalable pattern; per-region endpoints; rule SQL is not standard SQL.
# • Interview angle: `Iac.md` §Q-whirlpool (🟡CONFIRM).
#
# # L3/L4 — Kubernetes (EKS)
#
# │ Kubernetes concepts: see `../M5_kubernetes/kubernetes.md`.
# │ EKS AWS-specifics: see `../M9_AWS_Cloud.md` §1.3, §1.10.
# │ Where the line is: this group covers the AWS-side objects that create and wire a cluster
# │ (control plane, OIDC, identity, nodes, add-ons) and the Terraform that installs them. What runs
# │ *inside* the cluster (Deployments, Services, HPAs, policies) belongs to the Kubernetes notes.
# │ ✅REAL context: the cluster, VPC and node groups were in the platform team's separate
# │ Terraform repo; what this repo holds in this group is the Kubernetes-side material —
# │ the CloudWatch adapter, KEDA, PV/PVC (R47, R49) — and the IRSA-style IAM role (R22/R40).
