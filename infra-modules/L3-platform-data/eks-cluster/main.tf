# ════════════════════════════════════════════════════════════════════════
#  MODULE : eks-cluster
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R39 [Tier A]  →  Iac_blueprint_masterclass.md, "R39"
#  Depends on : vpc, kms, iam-roles
#  Consumed by: nodes, irsa, add-ons, nlb
#  Inputs  : variables below (cross-layer ones are fed by the live leaf from the SSM contract)
#  Outputs : published to SSM /<org>/<env>/platform/<key>  (see PUBLISH below the code)
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

variable "k8s_version" {
  type        = string
  description = "EKS Kubernetes version (upgrade one minor at a time)"
}

variable "kms_key_arn" {
  type        = string
  description = "Kms key arn — read from the SSM contract (/<org>/<env>/security/kms_key_arn, published by kms)"
}

variable "office_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the (non-prod) public EKS endpoint"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

variable "sg_cluster_extra_id" {
  type        = string
  description = "Sg cluster extra id — read from the SSM contract (/<org>/<env>/network/sg_cluster_extra_id, published by security-groups)"
}

data "aws_iam_policy_document" "eks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "cluster" {
  name               = "${var.env}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_trust.json
}
resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = "${var.env}-eks"
  version  = var.k8s_version # e.g. "1.33" — upgrade one minor at a time
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids # control-plane ENIs go in these
    security_group_ids      = [var.sg_cluster_extra_id]
    endpoint_private_access = true
    endpoint_public_access  = var.env != "prod" # prod: private-only API
    public_access_cidrs     = var.env != "prod" ? var.office_cidrs : null
  }

  access_config {
    authentication_mode                         = "API" # access entries only; no aws-auth ConfigMap
    bootstrap_cluster_creator_admin_permissions = false # nobody is secretly admin
  }

  encryption_config {
    resources = ["secrets"]
    provider { key_arn = var.kms_key_arn } # envelope-encrypt Kubernetes Secrets in etcd
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  upgrade_policy { support_type = "STANDARD" } # avoid the extended-support surcharge

  depends_on = [aws_iam_role_policy_attachment.cluster] # role must have its policy BEFORE the cluster uses it
  lifecycle { prevent_destroy = true }
}

resource "aws_cloudwatch_log_group" "eks" { # create it yourself so you control retention (R64)
  name              = "/aws/eks/${aws_eks_cluster.this.name}/cluster"
  retention_in_days = var.env == "prod" ? 400 : 30
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/platform/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/platform"
  contract_strings = merge(
    {
      cluster_name            = aws_eks_cluster.this.name
      cluster_arn             = aws_eks_cluster.this.arn
      cluster_endpoint        = aws_eks_cluster.this.endpoint
      cluster_oidc_issuer_url = aws_eks_cluster.this.identity[0].oidc[0].issuer
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
# EXPLAINED — R39 — EKS cluster (control plane)  [A]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# The EKS control plane is the Kubernetes brain (API server, scheduler, etcd) that AWS runs
# for you, across three AZs. Your IaC describes *version*, *which subnets*, *who can reach the API*,
# *what to log*, *whether secrets are encrypted*. Worker nodes are separate (R43).
#
# ── 2. Where it sits ──
# • Layer L3. Hard-depends on: VPC + private subnets (R9), a cluster IAM role, a KMS key (R18) for
#   secrets encryption, SGs.
# • Consumed by: the OIDC provider (R40), node groups (R43), add-ons (R45), access entries (R42),
#   the `kubernetes`/`helm` providers (R46).
# • Whirlpool: ❌ not in this repo — platform team's repo. 🧪IDEAL.
#
# The same thing as the community module (what the platform team most likely used):
#
# [hcl — illustration from the notes, NOT applied by this module]
#   module "eks" {
#     source  = "terraform-aws-modules/eks/aws"
#     version = "20.8.4"
#     cluster_name    = "${var.env}-eks"
#     cluster_version = var.k8s_version
#     vpc_id          = var.vpc_id
#     subnet_ids      = var.private_subnet_ids
#     enable_irsa     = true                         # creates the OIDC provider (R40)
#     eks_managed_node_groups = {
#       main = { instance_types = ["m5.2xlarge"]  min_size = 3  max_size = 20  desired_size = 5  disk_size = 100 }
#     }
#   }
#
# CFN type names (for recognition): `AWS::EKS::Cluster`, `AWS::EKS::Nodegroup`, `AWS::EKS::Addon`,
# `AWS::EKS::AccessEntry`. (The old donor CFN for this layer was only a sample, so it is dropped.)
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `version`
#       what it does: Kubernetes minor version
#       why it matters: Upgrades one minor at a time, control plane first, then nodes; EKS can only
#           go forward
#   ▸ `role_arn` + `AmazonEKSClusterPolicy`
#       what it does: The identity EKS uses to manage AWS resources for you
#       why it matters: Without the policy attached *before* the cluster is created, creation fails
#           or hangs
#   ▸ `vpc_config.subnet_ids`
#       what it does: Where the control plane puts its ENIs
#       why it matters: Needs ≥ 2 AZs; the cluster talks to your nodes through them
#   ▸ `endpoint_public_access` / `endpoint_private_access`
#       what it does: Who can reach the API server
#       why it matters: Prod = private only; both off = unreachable; both on = public with a CIDR
#           allow-list
#   ▸ `public_access_cidrs`
#       what it does: Allow-list for the public endpoint
#       why it matters: Default is `0.0.0.0/0` — wide open
#   ▸ `access_config.authentication_mode = "API"`
#       what it does: Use EKS access entries, not the `aws-auth` ConfigMap
#       why it matters: The modern, auditable way to grant cluster access (R42)
#   ▸ `bootstrap_cluster_creator_admin_permissions = false`
#       what it does: The creating identity is *not* an invisible admin
#       why it matters: Otherwise whoever ran `terraform apply` has hidden cluster-admin
#   ▸ `encryption_config … secrets`
#       what it does: Envelope-encrypts Secrets in etcd with your KMS key
#       why it matters: Without it Secrets are stored with AWS-managed encryption only
#   ▸ `enabled_cluster_log_types`
#       what it does: Control-plane logs → CloudWatch
#       why it matters: Off by default — you need `audit` to investigate an incident
#   ▸ `aws_cloudwatch_log_group` (explicit)
#       what it does: You own the retention
#       why it matters: Otherwise AWS creates it with no expiry — the cost-bomb pattern (R64)
#   ▸ `upgrade_policy.support_type`
#       what it does: `STANDARD` vs `EXTENDED` support
#       why it matters: Extended support carries a per-cluster-hour surcharge
#   ▸ `depends_on` the policy attachment
#       what it does: Forces order
#       why it matters: IAM changes are eventually consistent — races are real
#
# ── 7. How it connects ──
# • Consumes: VPC/subnets (R9), KMS (R18), SGs (R10).
# • Produces: cluster name, endpoint, OIDC issuer URL, cluster security group → published to SSM
#   (`/acme/<env>/platform/eks_*`, R20) → OIDC provider (R40), node groups (R43), add-ons (R45),
#   Helm releases (R48).
# • `VPC → EKS control plane → OIDC issuer → IAM OIDC provider → IRSA roles → pods`
# • If out of order: nodes cannot join before the cluster exists; the `kubernetes`/`helm` providers
#   cannot be configured until the cluster endpoint is known (R46 — the bootstrap problem).
#
# ── 8. Must-know box ──
# • Skeleton: cluster IAM role + `AmazonEKSClusterPolicy` · `aws_eks_cluster` (`version`,
#   `role_arn`, `vpc_config`, `access_config`, `encryption_config`, log types) · log group.
# • Gotchas:
#   • Control-plane logging is off by default.
#   • A public API endpoint with the default CIDR is the world.
#   • Kubernetes version skew: nodes may lag the control plane by a few minors but never lead it.
#   • Secrets encryption cannot be removed later, and enabling it later is a one-way door.
#   • Cluster creation takes ~10–15 minutes — set generous timeouts.
#   • Destroying a cluster before deleting LB-controller-created load balancers leaves orphaned ENIs
#     that block the VPC delete (§2.14).
#   • Node groups, add-ons and Helm releases must be destroyed before the cluster.
# • CFN vs TF difference: CloudFormation can create the cluster and node group but has no
#   first-class way to run `helm`/`kubectl` — Terraform's `helm`/`kubernetes` providers can, but see
#   R46 for why that is fragile.
# • Interview angle: `Iac.md` §Q-resources, §Q-architecture.
