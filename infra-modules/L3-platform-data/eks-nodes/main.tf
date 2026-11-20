# ════════════════════════════════════════════════════════════════════════
#  MODULE : eks-nodes
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R43 [Tier A]  →  Iac_blueprint_masterclass.md, "R43"
#  Depends on : eks-cluster, vpc
#  Consumed by: pods
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
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
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

variable "karpenter_version" {
  type        = string
  description = "Karpenter Helm chart version"
}

variable "kms_key_arn" {
  type        = string
  description = "Kms key arn — read from the SSM contract (/<org>/<env>/security/kms_key_arn, published by kms)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

data "aws_iam_policy_document" "node_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "node" {
  name               = "${var.env}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_trust.json
}
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", # pull images from ECR
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",       # Session Manager, no SSH
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}
# NOTE: the VPC CNI policy goes on the CNI add-on's IRSA role (R45), not on the node role.

resource "aws_launch_template" "nodes" {
  name_prefix = "${var.env}-nodes-"
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  } # IMDSv2; hop limit 1 stops pods reaching node creds
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 100
      volume_type = "gp3"
      encrypted   = true
      kms_key_id  = var.kms_key_arn
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.env}-eks-node" }
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = var.cluster_name
  node_group_name = "main"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = "AL2023_ARM_64_STANDARD" # Graviton / arm64
  capacity_type   = var.env == "prod" ? "ON_DEMAND" : "SPOT"
  instance_types  = ["m7g.xlarge", "m6g.xlarge"] # several sizes → better Spot availability

  scaling_config {
    min_size     = 3
    max_size     = 20
    desired_size = 5
  }
  update_config { max_unavailable_percentage = 25 }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  labels = { workload = "general" }
  taint {
    key    = "dedicated"
    value  = "general"
    effect = "NO_SCHEDULE"
  } # optional: reserve for specific pods

  lifecycle { ignore_changes = [scaling_config[0].desired_size] } # the autoscaler owns this
  depends_on = [aws_iam_role_policy_attachment.node]
}

# Karpenter controller identity (Pod Identity shown; IRSA works too) + an SQS queue for spot-interruption events
resource "aws_iam_role" "karpenter" {
  name               = "${var.env}-karpenter"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}
resource "aws_iam_role_policy" "karpenter" {
  role   = aws_iam_role.karpenter.id
  policy = data.aws_iam_policy_document.karpenter_controller.json # ec2:RunInstances/CreateFleet/Terminate…, iam:PassRole on the node role, sqs:*, eks:DescribeCluster, pricing:GetProducts
}
resource "aws_eks_pod_identity_association" "karpenter" {

  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter.arn
}
resource "aws_sqs_queue" "karpenter_interruptions" {
  name                      = "${var.env}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

# Karpenter-launched nodes must be allowed into the cluster
resource "aws_eks_access_entry" "karpenter_nodes" {

  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version
  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruptions.name
  }
  set {
    name  = "serviceAccount.name"
    value = "karpenter"
  }
}
# ─── Trust + policy documents the excerpt points at ───
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "karpenter_controller" {
  statement {
    sid = "NodeLifecycle"
    actions = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate", "ec2:CreateTags",
    "ec2:TerminateInstances", "ec2:DeleteLaunchTemplate", "ec2:Describe*"]
    resources = ["*"]
  }
  statement {
    sid       = "PassNodeRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.node.arn]
  }
  statement {
    sid       = "ClusterAndPricing"
    actions   = ["eks:DescribeCluster", "pricing:GetProducts", "ssm:GetParameter"]
    resources = ["*"]
  }
  statement {
    sid       = "Interruptions"
    actions   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
    resources = [aws_sqs_queue.karpenter_interruptions.arn]
  }
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R43 — Managed node groups (+ launch template, taints, labels, arm64) **and Karpenter**  [A]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# Worker nodes are the EC2 instances your pods run on. A managed node group is an ASG that
# EKS creates and patches for you — you pick instance types and min/max. Karpenter is the
# modern alternative: it watches for *pending pods* and launches exactly the right instance in
# seconds, then removes nodes it no longer needs ("consolidation").
#
# ── 2. Where it sits ──
# • Layer L3/L4. Depends on: the cluster (R39), private subnets (R9), a node IAM role, the VPC CNI
#   add-on (R45), a node SG.
# • Consumed by: every pod. (Autoscaling pods is R49; autoscaling *nodes* is this resource.)
# • Whirlpool: ❌ the node groups were in the platform team's repo. ✅REAL clue: the service chart
#   sets `nodeSelector: kubernetes.io/arch: {{ .Values.arch }}` and the Dockerfile builds on
#   `arm64v8/amazoncorretto:17` — the fleet ran arm64 (Graviton) nodes. 🟡CONFIRM whether nodes were
#   static managed groups or Karpenter.
#
# 4b. Terraform + YAML — Karpenter
#
# The two Karpenter custom objects (Kubernetes CRDs, so they live as YAML, not as `resource
# "aws_*"`):
#
# [yaml — illustration from the notes, NOT applied by this module]
#   apiVersion: karpenter.k8s.aws/v1
#   kind: EC2NodeClass                    # the AWS side: AMI, subnets, SGs, role
#   metadata: { name: default }
#   spec:
#     amiSelectorTerms:  [{ alias: al2023@latest }]
#     role: <env>-eks-node-role
#     subnetSelectorTerms:        [{ tags: { "karpenter.sh/discovery": "<env>-eks" } }]
#     securityGroupSelectorTerms: [{ tags: { "karpenter.sh/discovery": "<env>-eks" } }]
#     metadataOptions: { httpTokens: required, httpPutResponseHopLimit: 1 }
#     blockDeviceMappings:
#       - { deviceName: /dev/xvda, ebs: { volumeSize: 100Gi, volumeType: gp3, encrypted: true } }
#   ---
#   apiVersion: karpenter.sh/v1
#   kind: NodePool                        # the scheduling side: what it may launch and when to remove
#   metadata: { name: default }
#   spec:
#     template:
#       spec:
#         nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: default }
#         requirements:
#           - { key: kubernetes.io/arch,         operator: In, values: [arm64, amd64] }
#           - { key: karpenter.sh/capacity-type, operator: In, values: [spot, on-demand] }
#           - { key: karpenter.k8s.aws/instance-category, operator: In, values: [c, m, r] }
#           - { key: karpenter.k8s.aws/instance-generation, operator: Gt, values: ["5"] }
#         expireAfter: 720h                # recycle nodes every 30 days → picks up new AMIs
#     limits: { cpu: "1000" }              # a hard ceiling so a bug cannot launch 10,000 nodes
#     disruption:
#       consolidationPolicy: WhenEmptyOrUnderutilized
#       consolidateAfter: 1m
#       budgets: [{ nodes: "10%" }]        # never disrupt more than 10% of nodes at once
#
# CFN type names: `AWS::EKS::Nodegroup`, `AWS::EC2::LaunchTemplate`. (Karpenter objects are
# Kubernetes CRDs — no CFN type.)
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ Node role + `AmazonEKSWorkerNodePolicy`
#       what it does: Lets kubelets register with the cluster
#       why it matters: Without it nodes never join (`NotReady`/not listed)
#   ▸ `AmazonEC2ContainerRegistryReadOnly`
#       what it does: Lets nodes pull from ECR
#       why it matters: Missing = `ImagePullBackOff` (R32)
#   ▸ `AmazonSSMManagedInstanceCore`
#       what it does: Session Manager access
#       why it matters: SSH-free node debugging
#   ▸ VPC CNI policy on the CNI add-on's role
#       what it does: Lets the CNI manage ENIs/IPs
#       why it matters: Putting it on the node role works but gives *every pod on the node* those
#           rights
#   ▸ `metadata_options` hop limit `1`
#       what it does: Pods cannot reach the node's instance-metadata credentials
#       why it matters: Otherwise any compromised pod can steal the node role
#   ▸ `ami_type = "AL2023_ARM_64_STANDARD"`
#       what it does: arm64 Graviton AMI
#       why it matters: Must match the image architecture (✅REAL: arm64 images) — a mismatch gives
#           `exec format error`
#   ▸ `capacity_type = "SPOT"`
#       what it does: Cheaper interruptible nodes
#       why it matters: Non-prod only unless workloads tolerate interruption
#   ▸ multiple `instance_types`
#       what it does: Pool of acceptable sizes
#       why it matters: One type = Spot capacity errors
#   ▸ `scaling_config` + `ignore_changes[desired_size]`
#       what it does: min/max/desired
#       why it matters: Without `ignore_changes`, every apply resets the autoscaler's number
#   ▸ `update_config.max_unavailable_percentage`
#       what it does: How many nodes drain at once during AMI upgrades
#       why it matters: Too high = capacity dip; too low = slow
#   ▸ `taint` / `labels`
#       what it does: Reserve nodes / label for scheduling
#       why it matters: Pods need a matching `toleration` / `nodeSelector`
#   ▸ Karpenter `NodePool.requirements`
#       what it does: The menu Karpenter may pick from
#       why it matters: Narrow = predictable; wide = cheaper bin-packing
#   ▸ `limits.cpu`
#       what it does: Hard cap on total capacity
#       why it matters: The safety fuse against runaway scale-up
#   ▸ `disruption.consolidationPolicy` + `budgets`
#       what it does: When/how fast nodes are removed
#       why it matters: Aggressive consolidation + no PDBs = pods evicted with no protection (✅REAL:
#           the repo has 0 PodDisruptionBudgets)
#   ▸ `expireAfter`
#       what it does: Max node lifetime
#       why it matters: Forces regular AMI refresh
#   ▸ `EC2NodeClass.*SelectorTerms`
#       what it does: Finds subnets/SGs by tag `karpenter.sh/discovery`
#       why it matters: If the tag is missing on your subnets, Karpenter launches nothing
#   ▸ `interruptionQueue`
#       what it does: SQS fed by EventBridge Spot/health events
#       why it matters: Lets Karpenter drain a node *before* AWS reclaims it
#
# ── 7. How it connects ──
# • Consumes: cluster (R39), subnets (R9), node SG, ECR/SSM permissions (R22), the CNI add-on (R45).
# • Produces: schedulable capacity → pods; node role ARN → access entry (R42).
# • `pending pod → Karpenter → EC2 Fleet → node joins (access entry, node role) → pod scheduled`
# • If out of order: nodes before the CNI add-on are `NotReady`; Karpenter before its IAM/queue
#   exists crash-loops; Karpenter nodes without an access entry never register.
#
# ── 8. Must-know box ──
# • Skeleton (managed node group): node role (3 policies) · launch template (IMDSv2, encrypted gp3)
#   · `aws_eks_node_group` (subnets, `ami_type`, `capacity_type`, `instance_types`,
#   `scaling_config`, `ignore_changes[desired_size]`).
# • Skeleton (Karpenter): controller identity + IAM + SQS · helm release · `EC2NodeClass` (AMI,
#   subnets/SGs by tag, role) · `NodePool` (requirements, `limits`, `disruption`).
# • Gotchas:
#   • AMI arch must match image arch (arm64 nodes + amd64 image = `exec format error`).
#   • Forgetting `ignore_changes` on `desired_size`.
#   • Spot in prod without interruption handling.
#   • Aggressive consolidation without PDBs and `preStop` drain causes dropped requests.
#   • Node role vs pod role: the node role is shared by everything on the node — keep it minimal and
#     use IRSA/Pod Identity for pod permissions.
#   • Managed node group upgrades are rolling *replacements* — a PDB that blocks drain stalls the
#     upgrade.
# • CFN vs TF difference: CFN `AWS::EKS::Nodegroup` covers managed groups; Karpenter is Helm + CRDs
#   in both worlds.
# • Interview angle: `Iac.md` §Q-resources, §Q-architecture.
