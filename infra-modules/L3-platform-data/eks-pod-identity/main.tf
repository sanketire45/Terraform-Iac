# ════════════════════════════════════════════════════════════════════════
#  MODULE : eks-pod-identity
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R41 [Tier B]  →  Iac_blueprint_masterclass.md, "R41"
#  Depends on : eks-cluster; pod-identity-agent add-on
#  Consumed by: workloads (alternative to IRSA)
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

resource "aws_eks_addon" "pod_identity" {
  cluster_name = var.cluster_name
  addon_name   = "eks-pod-identity-agent"
}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"] # TagSession is REQUIRED
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "external_secrets" {
  name               = "${var.env}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = var.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
  depends_on      = [aws_eks_addon.pod_identity]
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R41 — EKS Pod Identity  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# The newer, simpler alternative to IRSA. Instead of an OIDC provider and a long trust condition,
# you install an agent add-on on the nodes and associate a role with a
# (namespace, ServiceAccount) pair. The trust policy is the same for every role:
# `pods.eks.amazonaws.com`. No annotation, no per-cluster OIDC provider.
#
# ── 2. Where it sits ──
# L3/L4. Depends on: the cluster (R39) and the `eks-pod-identity-agent` add-on (R45). Consumed by:
# pods.
#
# CFN type name: `AWS::EKS::PodIdentityAssociation`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `eks-pod-identity-agent` add-on
#       what it does: A DaemonSet that serves credentials to pods
#       why it matters: No agent = no credentials; associations alone do nothing
#   ▸ `pods.eks.amazonaws.com` principal
#       what it does: The EKS service as the trusted party
#       why it matters: Same trust for every role — no per-cluster values
#   ▸ `sts:TagSession`
#       what it does: Lets EKS attach session tags
#       why it matters: Omit it and the association silently fails
#   ▸ `aws_eks_pod_identity_association`
#       what it does: Maps (namespace, ServiceAccount) → role
#       why it matters: This is the whole binding — no annotation on the SA
#
# ── 7. How it connects ──
# `pod → Pod Identity agent (node) → EKS Auth API → role → credentials`. If out of order:
# association created before the agent add-on → pods get no credentials.
#
# ── 8. Must-know box — IRSA vs Pod Identity ──
#
#   ▸ Setup
#       irsa: OIDC provider per cluster + annotated SA
#       pod identity: Agent add-on + association
#   ▸ Trust policy
#       irsa: Cluster-specific (OIDC URL, `:sub`, `:aud`)
#       pod identity: Identical for every role (`pods.eks.amazonaws.com`)
#   ▸ Cross-cluster reuse
#       irsa: Role trust must be edited per cluster
#       pod identity: One role, many clusters
#   ▸ Works on Fargate
#       irsa: Yes
#       pod identity: No (EC2 nodes only)
#   ▸ Works outside EKS (EKS Anywhere, self-managed)
#       irsa: Yes
#       pod identity: No
#   ▸ Role limits
#       irsa: Trust policy size can cap how many SAs one role trusts
#       pod identity: Association is separate from the trust policy
#
# • Gotchas: needs the agent DaemonSet on EC2 nodes (not Fargate); `sts:TagSession` in the trust
#   policy; association is per ServiceAccount name, so the SA must exist with that name; a pod using
#   both mechanisms follows the SDK's credential chain order.
# • Interview angle: `Iac.md` §Q-resources ("IRSA vs Pod Identity").
