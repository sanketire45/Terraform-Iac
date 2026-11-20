# ════════════════════════════════════════════════════════════════════════
#  MODULE : eks-irsa
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R40 [Tier A]  →  Iac_blueprint_masterclass.md, "R40"
#  Depends on : eks-cluster (OIDC issuer must exist)
#  Consumed by: every workload needing AWS access
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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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

variable "cluster_oidc_issuer_url" {
  type        = string
  description = "Cluster oidc issuer url — read from the SSM contract (/<org>/<env>/platform/cluster_oidc_issuer_url, published by eks-cluster)"
}

variable "prefix" {
  type        = string
  description = "Naming prefix for IAM objects (e.g. the permissions boundary)"
}

# STEP 1 — register the cluster's OIDC issuer with IAM (needs the cluster to exist)
data "tls_certificate" "eks" {
  url = var.cluster_oidc_issuer_url
}
resource "aws_iam_openid_connect_provider" "eks" {
  url             = var.cluster_oidc_issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# STEP 2 — a role that trusts that provider for ONE service account only
locals {
  oidc_host = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}
data "aws_iam_policy_document" "irsa_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "ebs_csi" {
  name                 = "${var.env}-EBS-CSI-Driver"
  assume_role_policy   = data.aws_iam_policy_document.irsa_trust.json
  permissions_boundary = "arn:aws:iam::${var.account_id}:policy/${var.prefix}-permissions-boundary"
}
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
# ─── The other IRSA roles the cluster needs — same trust shape, one map ───
variable "lbc_policy_arn" {
  type        = string
  description = "Customer-managed policy for the AWS Load Balancer Controller (published by iam-roles / platform team)"
}
locals {
  irsa_roles = {
    efs_csi = { sa = "kube-system:efs-csi-controller-sa", policy = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy" }
    vpc_cni = { sa = "kube-system:aws-node", policy = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" }
    lbc     = { sa = "kube-system:aws-load-balancer-controller", policy = var.lbc_policy_arn }
  }
}
data "aws_iam_policy_document" "irsa_trust_each" {
  for_each = local.irsa_roles
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${each.value.sa}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "irsa" {
  for_each             = local.irsa_roles
  name                 = "${var.env}-${replace(each.key, "_", "-")}"
  assume_role_policy   = data.aws_iam_policy_document.irsa_trust_each[each.key].json
  permissions_boundary = "arn:aws:iam::${var.account_id}:policy/${var.prefix}-permissions-boundary"
}
resource "aws_iam_role_policy_attachment" "irsa" {
  for_each   = local.irsa_roles
  role       = aws_iam_role.irsa[each.key].name
  policy_arn = each.value.policy
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/platform/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/platform"
  contract_strings = merge(
    {
      oidc_provider_arn = aws_iam_openid_connect_provider.eks.arn
      role_ebs_csi_arn  = aws_iam_role.ebs_csi.arn
    },
    { for k, v in aws_iam_role.irsa : "role_${k}_arn" => v.arn },
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
# EXPLAINED — R40 — EKS OIDC provider + IRSA role + ServiceAccount  [A]  ✅REAL (the role pattern)
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# IRSA (IAM Roles for Service Accounts) lets a pod — not the whole node — assume an IAM
# role. The cluster has its own OIDC identity issuer; you register it with IAM as an "identity
# provider", then write roles that *trust that provider* but only for one specific
# ServiceAccount. The pod gets a short-lived token, swaps it with STS for temporary AWS
# credentials, and never holds a long-lived key.
#
# ── 2. Where it sits ──
# • Layer L3/L4. Hard-depends on: the EKS cluster (R39) existing (its OIDC issuer URL is only known
#   after creation).
# • Consumed by: any pod needing AWS access — EBS CSI driver, ExternalDNS, the LB controller,
#   External Secrets Operator, KEDA's CloudWatch scaler, the CloudWatch adapter.
# • Whirlpool: ✅REAL — `top-layer-IAC/role/<env>/role.yaml` contains an IRSA role for the EBS CSI
#   driver (see R22 block 3 for the real trust policy). The OIDC provider itself is platform-team
#   infrastructure. The `ServiceAccount` annotation side is the Kubernetes half. 🟡CONFIRM whether
#   any *application* (not just platform add-ons) used IRSA.
#
# STEP 3 — the Kubernetes half (a `ServiceAccount` annotated with the role ARN):
#
# [yaml — illustration from the notes, NOT applied by this module]
#   apiVersion: v1
#   kind: ServiceAccount
#   metadata:
#     name: ebs-csi-controller-sa
#     namespace: kube-system
#     annotations:
#       eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT>:role/<env>-EBS-CSI-Driver
#
# The IRSA mental model:
#
# [text — illustration from the notes, NOT applied by this module]
#   Pod  ──uses──►  ServiceAccount (annotated with role ARN)
#    │
#    └─ EKS injects a projected volume: a short-lived OIDC token (audience = sts.amazonaws.com)
#         └─ AWS SDK calls sts:AssumeRoleWithWebIdentity with that token
#              └─ STS verifies the token against the registered OIDC provider
#                   └─ checks  :sub  (exact namespace/serviceaccount)  and  :aud  (sts.amazonaws.com)
#                        └─ returns temporary credentials → the pod calls AWS APIs
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `aws_eks_cluster.this.identity[0].oidc[0].issuer`
#       what it does: The cluster's OIDC issuer URL
#       why it matters: Only known after the cluster exists — the ordering root cause
#   ▸ `data "tls_certificate"`
#       what it does: Fetches the issuer's TLS thumbprint
#       why it matters: IAM needs a thumbprint when registering the provider
#   ▸ `aws_iam_openid_connect_provider`
#       what it does: Registers the issuer as a trusted IAM identity provider
#       why it matters: Without it every IRSA role fails with `InvalidIdentityToken`
#   ▸ `client_id_list = ["sts.amazonaws.com"]`
#       what it does: Accepted token audience
#       why it matters: Matches the `:aud` condition
#   ▸ `replace(…url, "https://", "")`
#       what it does: The issuer *host* (no scheme)
#       why it matters: IAM condition keys use `oidc.eks.<region>.amazonaws.com/id/<ID>:sub`, not
#           the full URL
#   ▸ `Principal.Federated`
#       what it does: Trusts that provider
#       why it matters: The OIDC flavour of "who may assume"
#   ▸ `:sub = system:serviceaccount:<ns>:<name>`
#       what it does: Pins the role to one ServiceAccount
#       why it matters: Drop it and any pod in the cluster can assume the role
#   ▸ `:aud = sts.amazonaws.com`
#       what it does: Pins the token audience
#       why it matters: Stops token reuse across audiences
#   ▸ `eks.amazonaws.com/role-arn` annotation
#       what it does: Tells EKS which role to inject
#       why it matters: Without it the pod falls back to the node's role (too much power)
#
# ── 7. How it connects ──
# • Consumes: the cluster's OIDC issuer URL (R39 output).
# • Produces: role ARN → ServiceAccount annotation → add-on `service_account_role_arn` (R45) / Helm
#   `serviceAccount.annotations` (R48).
# • Order (three steps inside "step 10" of §2.14): cluster → OIDC provider → IRSA roles. IRSA before
#   the provider = `InvalidIdentityToken`.
# • If out of order: a role referencing a provider that does not exist is rejected as
#   `MalformedPolicyDocument`/`Principal not found`.
#
# ── 8. Must-know box ──
# • Skeleton: OIDC provider (`url`, `client_id_list`, thumbprint) · role with
#   `AssumeRoleWithWebIdentity` + `:sub` + `:aud` · policy attachment · annotated ServiceAccount.
# • Gotchas:
#   • Create order: cluster → OIDC provider → role → annotated ServiceAccount.
#   • `:sub` is exact (`system:serviceaccount:<ns>:<sa>`), case-sensitive — a typo means
#     `AccessDenied` with no obvious clue.
#   • One OIDC provider per cluster (so one per region/account where clusters live).
#   • A role per ServiceAccount, not one shared "pods" role.
#   • Pods must use the SDK's default credential chain (older SDK versions do not support
#     web-identity).
#   • ✅REAL: the EBS CSI role trusts only `kube-system:ebs-csi-controller-sa` — the textbook
#     least-privilege shape.
# • CFN vs TF difference: CFN needs the OIDC provider ID pasted in as a parameter or imported (the
#   real file hard-codes the provider path); Terraform derives it from the cluster resource, so it
#   cannot drift.
# • Interview angle: `Iac.md` §Q-resources ("EKS→OIDC→IRSA ordering", "IRSA vs Pod Identity"),
#   §Q-whirlpool.
