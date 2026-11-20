# ════════════════════════════════════════════════════════════════════════
#  MODULE : eks-fargate
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R44 [Tier C]  →  Iac_blueprint_masterclass.md, "R44"
#  Depends on : eks-cluster
#  Consumed by: serverless pods
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

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

resource "aws_iam_role" "fargate" {
  name               = "${var.env}-eks-fargate"
  assume_role_policy = data.aws_iam_policy_document.fargate_trust.json # principal: eks-fargate-pods.amazonaws.com
}
resource "aws_iam_role_policy_attachment" "fargate" {
  role       = aws_iam_role.fargate.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}
resource "aws_eks_fargate_profile" "batch" {
  cluster_name           = var.cluster_name
  fargate_profile_name   = "batch"
  pod_execution_role_arn = aws_iam_role.fargate.arn
  subnet_ids             = var.private_subnet_ids # PRIVATE subnets only
  selector {
    namespace = "batch"
    labels    = { runtime = "fargate" }
  }
}
data "aws_iam_policy_document" "fargate_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks-fargate-pods.amazonaws.com"]
    }
  }
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R44 — EKS Fargate profiles  [C]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# • Skeleton: pod-execution role · profile (private subnets, selector by namespace/labels).
# • Gotchas: private subnets only; no DaemonSets (so agents must be sidecars); no Pod Identity (IRSA
#   only); no GPUs, limited volume types (EFS yes, EBS no); CoreDNS needs patching to run on
#   Fargate-only clusters; each pod is its own micro-VM (cost + slower start).
# • CFN type name: `AWS::EKS::FargateProfile`.
