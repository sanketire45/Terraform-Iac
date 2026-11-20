# ════════════════════════════════════════════════════════════════════════
#  MODULE : opensearch
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R28 [Tier B]  →  Iac_blueprint_masterclass.md, "R28"
#  Depends on : vpc, kms
#  Consumed by: logs/search
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

variable "admin_role_arn" {
  type        = string
  description = "IAM role allowed to administer the resource (OpenSearch domain access policy)"
}

variable "kms_key_arn" {
  type        = string
  description = "Kms key arn — read from the SSM contract (/<org>/<env>/security/kms_key_arn, published by kms)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

variable "sg_opensearch_id" {
  type        = string
  description = "Sg opensearch id — read from the SSM contract (/<org>/<env>/network/sg_opensearch_id, published by security-groups)"
}

resource "aws_opensearch_domain" "this" {
  domain_name    = "${var.env}-logs"
  engine_version = "OpenSearch_2.11"

  cluster_config {
    instance_type          = "r6g.large.search"
    instance_count         = 3
    zone_awareness_enabled = true
    zone_awareness_config { availability_zone_count = 3 }
    dedicated_master_enabled = true
    dedicated_master_type    = "m6g.large.search"
    dedicated_master_count   = 3
  }
  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = 200
  }

  vpc_options {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_opensearch_id]
  }
  encrypt_at_rest {
    enabled    = true
    kms_key_id = var.kms_key_arn
  }
  node_to_node_encryption { enabled = true }
  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = false
    master_user_options { master_user_arn = var.admin_role_arn } # fine-grained access via IAM, not a password
  }
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R28 — OpenSearch domain  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# Managed search/analytics (Elasticsearch's successor). Used for log search and full-text search.
# A domain is the cluster; VPC-attached domains are reachable only from inside your network.
#
# ── 2. Where it sits ──
# L3. Depends on: VPC, SG, KMS. Consumed by: log pipelines (Firehose R37), apps.
#
# CFN type name: `AWS::OpenSearchService::Domain`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `zone_awareness_enabled` + `availability_zone_count`
#       what it does: Spread nodes across AZs
#       why it matters: Instance count must be a multiple of the AZ count
#   ▸ `dedicated_master_*`
#       what it does: Three dedicated master nodes
#       why it matters: Cluster stability; without them a busy data node can destabilise the cluster
#   ▸ `ebs_options`
#       what it does: Storage per node
#       why it matters: Search is storage-hungry — size it for growth
#   ▸ `vpc_options`
#       what it does: Puts the domain in your VPC
#       why it matters: Cannot be switched between VPC and public after creation
#   ▸ `encrypt_at_rest`, `node_to_node_encryption`
#       what it does: Encryption
#       why it matters: Both are create-time; required for fine-grained access control
#   ▸ `enforce_https` + `tls_security_policy`
#       what it does: TLS-only access
#       why it matters: Baseline security
#   ▸ `advanced_security_options`
#       what it does: Fine-grained access control
#       why it matters: Requires encryption + HTTPS; `master_user_arn` avoids a stored password
#
# ── 7. How it connects ──
# `Firehose / app → domain endpoint (VPC) ← dashboards`. Domain access policy + SG both must allow
# the caller.
#
# ── 8. Must-know box ──
# • Skeleton: `engine_version` · `cluster_config` · `ebs_options` · `vpc_options` · encryption (rest
#   + node-to-node + HTTPS) · fine-grained access.
# • Gotchas: VPC vs public is permanent; domain creation takes 20–40 minutes; changing instance type
#   triggers a blue/green deploy; the resource-based access policy and IAM both apply; a
#   service-linked role for OpenSearch must exist in the account.
# • Interview angle: `Iac.md` §Q-resources.
