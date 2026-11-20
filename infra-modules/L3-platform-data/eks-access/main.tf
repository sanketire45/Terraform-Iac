# ════════════════════════════════════════════════════════════════════════
#  MODULE : eks-access
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R42 [Tier B]  →  Iac_blueprint_masterclass.md, "R42"
#  Depends on : eks-cluster
#  Consumed by: human + CI access to the cluster
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

variable "cluster_name" {
  type        = string
  description = "Cluster name — read from the SSM contract (/<org>/<env>/platform/cluster_name, published by eks-cluster)"
}

variable "dev_role_arn" {
  type        = string
  description = "Developer role that gets read-only / launch access"
}

variable "platform_admin_role_arn" {
  type        = string
  description = "Role mapped to cluster-admin through an EKS access entry"
}

resource "aws_eks_access_entry" "platform_admins" {
  cluster_name  = var.cluster_name
  principal_arn = var.platform_admin_role_arn # an IAM role (e.g. the SSO admin role)
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "platform_admins" {
  cluster_name  = var.cluster_name
  principal_arn = aws_eks_access_entry.platform_admins.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}

resource "aws_eks_access_entry" "dev_readonly" {
  cluster_name      = var.cluster_name
  principal_arn     = var.dev_role_arn
  kubernetes_groups = ["viewers"] # bind to a Kubernetes RBAC group instead
}
resource "aws_eks_access_policy_association" "dev_view" {
  cluster_name  = var.cluster_name
  principal_arn = aws_eks_access_entry.dev_readonly.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  access_scope {
    type       = "namespace"
    namespaces = ["payments", "orders"]
  } # scoped to namespaces
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R42 — EKS access entries vs the legacy `aws-auth` ConfigMap  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# How an IAM identity is allowed to talk to the Kubernetes API. The old way was editing a
# ConfigMap called `aws-auth` by hand — easy to break, impossible to audit, one typo locks everyone
# out. Access entries are a proper AWS API: each entry maps an IAM principal to Kubernetes
# permissions, with built-in policies.
#
# ── 2. Where it sits ──
# L3. Depends on: the cluster (R39) with `authentication_mode = "API"` or `"API_AND_CONFIG_MAP"`.
# Consumed by: humans, CI, node roles.
#
# CFN type name: `AWS::EKS::AccessEntry`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `aws_eks_access_entry.principal_arn`
#       what it does: The IAM role/user allowed in
#       why it matters: Without an entry that identity is denied (with `API` mode)
#   ▸ `type = "STANDARD"` / `"EC2_LINUX"`
#       what it does: Normal user vs node-role entry
#       why it matters: Node roles need `EC2_LINUX` so nodes can join
#   ▸ `aws_eks_access_policy_association`
#       what it does: Attach an AWS-managed Kubernetes policy
#       why it matters: `AmazonEKSClusterAdminPolicy`, `…AdminPolicy`, `…EditPolicy`, `…ViewPolicy`
#   ▸ `access_scope { type = "namespace" }`
#       what it does: Limit to namespaces
#       why it matters: Least privilege per team
#   ▸ `kubernetes_groups`
#       what it does: Map to RBAC groups you define
#       why it matters: For custom RBAC beyond the built-in policies
#
# ── 7. How it connects ──
# `IAM role → access entry → Kubernetes permissions`; node roles also need entries so kubelets can
# register. If out of order: an entry before the cluster exists fails; switching
# `authentication_mode` removes the old `aws-auth` mapping effect — migrate entries first.
#
# ── 8. Must-know box ──
# • Skeleton: `access_config.authentication_mode = "API"` · `aws_eks_access_entry` (principal) ·
#   `aws_eks_access_policy_association` (policy + scope).
# • Gotchas: the creator-admin bootstrap flag (R39); switching modes is one-way (CONFIG_MAP →
#   API_AND_CONFIG_MAP → API); `aws-auth` edits by hand are the legacy anti-pattern; entries are per
#   cluster so 12 clusters = 12 sets (loop with `for_each`).
# • Why the new API exists: the ConfigMap is a Kubernetes object any cluster-admin can break; access
#   entries are AWS-managed, auditable in CloudTrail, and don't lock you out if the ConfigMap is
#   damaged.
# • Interview angle: `Iac.md` §Q-resources ("`aws-auth` ConfigMap vs access entries").
