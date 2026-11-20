# ════════════════════════════════════════════════════════════════════════
#  MODULE : eks-managed-addons
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R45 [Tier B]  →  Iac_blueprint_masterclass.md, "R45"
#  Depends on : eks-cluster, eks-nodes
#  Consumed by: cluster networking/storage
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

variable "addon_versions" {
  type        = map(string)
  description = "Map of EKS add-on name → pinned version (never \"latest\": add-on upgrades are deliberate PRs)"
}

variable "cluster_name" {
  type        = string
  description = "Cluster name — read from the SSM contract (/<org>/<env>/platform/cluster_name, published by eks-cluster)"
}

variable "role_ebs_csi_arn" {
  type        = string
  description = "Role ebs csi arn — read from the SSM contract (/<org>/<env>/platform/role_ebs_csi_arn, published by eks-irsa)"
}

variable "role_efs_csi_arn" {
  type        = string
  description = "Role efs csi arn — read from the SSM contract (/<org>/<env>/platform/role_efs_csi_arn, published by eks-irsa)"
}

variable "role_vpc_cni_arn" {
  type        = string
  description = "Role vpc cni arn — read from the SSM contract (/<org>/<env>/platform/role_vpc_cni_arn, published by eks-irsa)"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = var.cluster_name
  addon_name                  = "vpc-cni"
  addon_version               = var.addon_versions["vpc-cni"] # pin it
  service_account_role_arn    = var.role_vpc_cni_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true",
      WARM_PREFIX_TARGET       = "1"
    } # more pod IPs per node
  })
}
resource "aws_eks_addon" "coredns" {
  cluster_name  = var.cluster_name
  addon_name    = "coredns"
  addon_version = var.addon_versions["coredns"]
}
resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = var.cluster_name
  addon_name    = "kube-proxy"
  addon_version = var.addon_versions["kube-proxy"]
}

resource "aws_eks_addon" "ebs_csi" { # ✅REAL pattern: add-on + the IRSA role from role.yaml
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = var.addon_versions["aws-ebs-csi-driver"]
  service_account_role_arn = var.role_ebs_csi_arn # R40
}
resource "aws_eks_addon" "efs_csi" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-efs-csi-driver"
  service_account_role_arn = var.role_efs_csi_arn
}
resource "aws_eks_addon" "pod_identity" {
  cluster_name = var.cluster_name
  addon_name   = "eks-pod-identity-agent"
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R45 — EKS managed add-ons  [B]  ✅REAL (EBS CSI pattern)
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# Add-ons are the components that make a cluster usable — networking (`vpc-cni`), DNS
# (`coredns`), service routing (`kube-proxy`), storage (`aws-ebs-csi-driver`, `aws-efs-csi-driver`),
# pod credentials (`eks-pod-identity-agent`). EKS can install and upgrade them for you; the
# alternative is hand-applied manifests or Helm.
#
# ── 2. Where it sits ──
# L3/L4. Depends on: the cluster (R39), IRSA roles for the ones needing AWS access (R40). Consumed
# by: nodes (CNI), pods (DNS, volumes).
# Whirlpool: ✅REAL *pattern* — the EBS CSI driver's IRSA role is in `role/<env>/role.yaml`
# (R22/R40). The add-on resource itself was in the platform repo.
#
# │ CloudFormation type name for recognition: `AWS::EKS::Addon` (`AddonName`, `AddonVersion`,
# │ `ServiceAccountRoleArn`, `ResolveConflicts`). The add-on resource itself lived in the platform
# │ team's repo, so no CFN block is shown here — only the IRSA role it uses is ✅REAL (R22).
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `addon_version`
#       what it does: Pin the add-on version
#       why it matters: Otherwise EKS picks the default, which changes between cluster versions
#   ▸ `service_account_role_arn`
#       what it does: IRSA role for the add-on's ServiceAccount
#       why it matters: No role = the driver cannot call AWS (EBS volumes never attach)
#   ▸ `resolve_conflicts_on_create = "OVERWRITE"`
#       what it does: Replace any pre-existing self-managed install
#       why it matters: Needed when adopting the default CNI/CoreDNS/kube-proxy
#   ▸ `resolve_conflicts_on_update = "PRESERVE"`
#       what it does: Keep your manual config changes
#       why it matters: `OVERWRITE` would wipe customisation on every upgrade
#   ▸ `configuration_values`
#       what it does: Add-on settings (JSON)
#       why it matters: e.g. prefix delegation for the CNI
#   ▸ `ENABLE_PREFIX_DELEGATION`
#       what it does: Give each ENI /28 prefixes instead of single IPs
#       why it matters: Multiplies pod density per node and avoids IP exhaustion
#   ▸ `depends_on` node group (CoreDNS, EBS CSI)
#       what it does: Waits for nodes
#       why it matters: CoreDNS/CSI pods cannot schedule with no nodes and the add-on create times
#           out
#
# ── 7. How it connects ──
# `IRSA role (R40) → add-on → controller pod → AWS API`; `CSI driver → StorageClass (R47) → PVC →
# pod`. If out of order: CoreDNS/CSI before any node exists → add-on stuck `CREATING`; CSI add-on
# before its IRSA role → pods crash-loop with `AccessDenied`.
#
# ── 8. Must-know box ──
# • Skeleton: `aws_eks_addon` (cluster, name, version, `service_account_role_arn`,
#   `resolve_conflicts_on_*`) for vpc-cni, coredns, kube-proxy, ebs-csi, efs-csi,
#   pod-identity-agent.
# • Gotchas: pin versions; CoreDNS/CSI need nodes first; `OVERWRITE` on update erases customisation;
#   the add-on version must be compatible with the cluster minor (list with `aws eks
#   describe-addon-versions`); the CNI controls how many pods fit per node (R9 subnet sizing).
# • Interview angle: `Iac.md` §Q-resources.
