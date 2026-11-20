# ════════════════════════════════════════════════════════════════════════
#  MODULE : msk
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R30 [Tier A]  →  Iac_blueprint_masterclass.md, "R30"
#  Depends on : vpc, security-groups, kms, private-ca
#  Consumed by: event backbone
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

variable "private_ca_arn" {
  type        = string
  description = "Private ca arn — read from the SSM contract (/<org>/<env>/security/private_ca_arn, published by private-ca)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

variable "sg_msk_id" {
  type        = string
  description = "Sg msk id — read from the SSM contract (/<org>/<env>/network/sg_msk_id, published by security-groups)"
}

resource "aws_msk_configuration" "this" {
  name              = "${var.env}-msk-config"
  kafka_versions    = ["3.5.1"]
  server_properties = <<-PROPS
    auto.create.topics.enable=false
    default.replication.factor=3
    min.insync.replicas=2
    num.partitions=6
    log.retention.hours=168
    unclean.leader.election.enable=false
  PROPS
}

resource "aws_msk_cluster" "this" {
  cluster_name           = "${var.env}-msk"
  kafka_version          = "3.5.1"
  number_of_broker_nodes = 3 # a multiple of the AZ/subnet count

  broker_node_group_info {
    instance_type   = "kafka.m5.xlarge"
    client_subnets  = var.private_subnet_ids # one per AZ
    security_groups = [var.sg_msk_id]
    storage_info {
      ebs_storage_info { volume_size = 1000 }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = var.kms_key_arn
    encryption_in_transit {
      client_broker = "TLS" # clients must use TLS
      in_cluster    = true
    }
  }

  client_authentication {
    tls { certificate_authority_arns = [var.private_ca_arn] } # mTLS
  }

  enhanced_monitoring = "PER_TOPIC_PER_BROKER" # the metrics KEDA scales on
  open_monitoring {
    prometheus {
      jmx_exporter { enabled_in_broker = true }
      node_exporter { enabled_in_broker = true }
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }
}
# helper log groups the excerpt referenced
resource "aws_cloudwatch_log_group" "msk" {
  name              = "/${var.env}/msk"
  retention_in_days = 30
  kms_key_id        = null # set to a CMK ARN where the log content is sensitive
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/data/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/data"
  contract_strings = merge(
    {
      msk_bootstrap_brokers_tls = aws_msk_cluster.this.bootstrap_brokers_tls
      msk_cluster_arn           = aws_msk_cluster.this.arn
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
# EXPLAINED — R30 — Amazon MSK (Kafka) cluster + configuration + client mTLS  [A]  ✅REAL (client side)
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# MSK is managed Kafka — the event backbone for this IoT platform (device events → IoT
# Core → MSK topics → microservice consumers). The brokers live in private subnets; clients
# authenticate with mutual TLS (mTLS): each client presents a certificate, the broker checks it
# against a trusted CA.
#
# ── 2. Where it sits ──
# • Layer L3 (data/integration). Depends on: VPC + private subnets (R9), SG (R10), KMS (R18), a
#   Private CA (R23) for mTLS.
# • Consumed by: services (client keystores/truststores), KEDA autoscaling (R49 scales consumers on
#   MSK metrics), IoT Core rules.
# • Whirlpool: ✅REAL client values only — `ground-layer-IAC/msk/values-key-<env>.yaml` ×7. The
#   cluster is in the platform team's repo, so the cluster below is written in Terraform, 🧪IDEAL.
# ✅REAL receipts: the per-env cluster names appear in the KEDA ScaledObjects as `ClusterName:
# prod-msk`, `BrokerID: 3`, and a topic dimension — MSK CloudWatch metrics are what drive
# autoscaling.
#
# CFN type names (for recognition): `AWS::MSK::Cluster`, `AWS::MSK::Configuration`. (A sample CFN
# cluster used `ClientBroker: TLS` and `ClientAuthentication: Tls: CertificateAuthorityArnList` —
# the same ideas.)
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `auto.create.topics.enable=false`
#       what it does: Topics must be created deliberately
#       why it matters: A typo in a producer otherwise silently creates a junk topic
#   ▸ `default.replication.factor=3` + `min.insync.replicas=2`
#       what it does: Each partition on 3 brokers; writes need 2 acks
#       why it matters: The durability pair — lose one broker and keep writing and not lose data
#   ▸ `unclean.leader.election.enable=false`
#       what it does: Never elect an out-of-sync replica
#       why it matters: Trades availability for no data loss
#   ▸ `number_of_broker_nodes`
#       what it does: Total brokers
#       why it matters: Must be a multiple of the number of client subnets
#   ▸ `client_subnets`
#       what it does: One per AZ
#       why it matters: Defines AZ spread; cannot be changed later
#   ▸ `encryption_in_transit.client_broker = "TLS"`
#       what it does: Clients must use TLS
#       why it matters: `TLS_PLAINTEXT` / `PLAINTEXT` would allow unencrypted clients
#   ▸ `client_authentication.tls` + `certificate_authority_arns`
#       what it does: mTLS with your Private CA
#       why it matters: This is why the clients carry a keystore
#   ▸ `enhanced_monitoring = "PER_TOPIC_PER_BROKER"`
#       what it does: Per-topic CloudWatch metrics
#       why it matters: KEDA/the CloudWatch adapter read these — without this level the topic-scoped
#           metrics do not exist
#   ▸ `open_monitoring`
#       what it does: Prometheus JMX/node exporters
#       why it matters: Scrape targets for metrics
#   ▸ `configuration_info.revision`
#       what it does: Which config version brokers use
#       why it matters: A config change needs a new revision and a rolling restart
#
# ── 7. How it connects ──
# • Consumes: subnets/SG, KMS key, Private CA.
# • Produces: bootstrap broker string (TLS) → SSM `/acme/<env>/data/msk_bootstrap` (R20) → service
#   config; CloudWatch metrics `AWS/Kafka` → KEDA ScaledObject (R49).
# • `IoT device → IoT Core rule → MSK topic → consumer pods (mTLS, keystore from Secrets Manager
#   R19) ; CloudWatch AWS/Kafka metrics → adapter/KEDA → HPA`
# • If out of order: MSK needs the CA active before the cluster references it; consumers deployed
#   before the bootstrap value is published cannot connect.
#
# ── 8. Must-know box ──
# • Skeleton: configuration (replication factor, min ISR) · cluster (version, brokers, subnets,
#   instance type, storage) · encryption (KMS + TLS) · mTLS via Private CA · enhanced monitoring ·
#   logging.
# • Gotchas:
#   • Client subnets and broker count are effectively immutable — plan capacity.
#   • Broker storage can only grow, never shrink.
#   • mTLS means every client needs a certificate — managing them in Git (✅REAL anti-pattern) is the
#     weak point.
#   • A MSK config change is a rolling broker restart.
#   • MSK metrics (`BytesInPerSec`) are a throughput proxy, not consumer lag — ✅REAL: the KEDA
#     autoscaler scales on `BytesInPerSec`; true lag needs consumer-group metrics.
#   • Public access is off by default and should stay off.
# • CFN vs TF difference: equivalent resources; Terraform's `aws_msk_configuration` is a separate
#   versioned object — the cluster pins a `revision`.
# • Interview angle: `Iac.md` §Q-whirlpool, §Q-resources.
