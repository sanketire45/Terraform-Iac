# ════════════════════════════════════════════════════════════════════════
#  MODULE : amp-grafana
#  Layer  : Lops-observability-backup-cost          Pipeline : pipeline-platform
#  Resource blueprint R65 [Tier C]  →  Iac_blueprint_masterclass.md, "R65"
#  Depends on : eks-irsa
#  Consumed by: metrics at scale
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

variable "cluster_arn" {
  type        = string
  description = "Cluster arn — read from the SSM contract (/<org>/<env>/platform/cluster_arn, published by eks-cluster)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

variable "role_grafana_arn" {
  type        = string
  description = "Role grafana arn — read from the SSM contract (/<org>/<env>/iam/role_grafana_arn, published by iam-roles)"
}

variable "sso_admin_group_id" {
  type        = string
  description = "Identity Center group granted Grafana admin"
}

resource "aws_prometheus_workspace" "this" {
  alias = "${var.env}-metrics"
  logging_configuration { log_group_arn = "${aws_cloudwatch_log_group.amp.arn}:*" }
}

resource "aws_grafana_workspace" "this" {
  name                     = "${var.env}-grafana"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  data_sources             = ["PROMETHEUS", "CLOUDWATCH"]
  role_arn                 = var.role_grafana_arn
}
resource "aws_grafana_role_association" "admins" {
  workspace_id = aws_grafana_workspace.this.id
  role         = "ADMIN"
  group_ids    = [var.sso_admin_group_id]
}
# Scraping: an agent-less managed collector, or a Prometheus/OTel agent doing remote_write with SigV4
resource "aws_prometheus_scraper" "eks" {
  source {
    eks {
      cluster_arn = var.cluster_arn
      subnet_ids  = var.private_subnet_ids
    }
  }
  destination {
    amp { workspace_arn = aws_prometheus_workspace.this.arn }
  }
  scrape_configuration = file("${path.module}/scrape.yml")
}
# helper log groups the excerpt referenced
resource "aws_cloudwatch_log_group" "amp" {
  name              = "/${var.env}/amp"
  retention_in_days = 30
  kms_key_id        = null # set to a CMK ARN where the log content is sensitive
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R65 — Amazon Managed Prometheus (AMP) + Managed Grafana (AMG)  [C]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# • Skeleton: AMP workspace · AMG workspace (+ SSO + role) · scraper/remote-write with an IAM role
#   (`aps:RemoteWrite`) · Grafana data sources.
# • Gotchas: AMP is storage + query, not the scraper — you still need a collector; remote-write
#   needs SigV4; AMG users come from IAM Identity Center (R4); alerting rules/Alertmanager config
#   are workspace-level resources.
# • CFN type names: `AWS::APS::Workspace`, `AWS::Grafana::Workspace`.
