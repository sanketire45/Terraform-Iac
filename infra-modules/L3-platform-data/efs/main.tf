# ════════════════════════════════════════════════════════════════════════
#  MODULE : efs
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R31 [Tier B]  →  Iac_blueprint_masterclass.md, "R31"
#  Depends on : vpc, security-groups, kms
#  Consumed by: RWX volumes for pods
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

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

variable "sg_efs_id" {
  type        = string
  description = "Sg efs id — read from the SSM contract (/<org>/<env>/network/sg_efs_id, published by security-groups)"
}

resource "aws_efs_file_system" "this" {
  creation_token   = "${var.env}-shared"
  encrypted        = true
  kms_key_id       = var.kms_key_arn
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic" # scales with demand; or "provisioned"
  lifecycle_policy { transition_to_ia = "AFTER_30_DAYS" }
  lifecycle_policy { transition_to_primary_storage_class = "AFTER_1_ACCESS" }
  lifecycle { prevent_destroy = true }
}

resource "aws_efs_mount_target" "this" {
  for_each        = toset(var.private_subnet_ids) # ONE PER AZ
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [var.sg_efs_id] # allow TCP 2049 from the node SG
}

resource "aws_efs_access_point" "app" {
  file_system_id = aws_efs_file_system.this.id
  posix_user {
    uid = 1000
    gid = 1000
  }
  root_directory {
    path = "/app"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }
}

resource "aws_efs_backup_policy" "this" {
  file_system_id = aws_efs_file_system.this.id
  backup_policy { status = "ENABLED" }
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/data/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/data"
  contract_strings = merge(
    {
      efs_id = aws_efs_file_system.this.id
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
# EXPLAINED — R31 — EFS file system + mount target per AZ + access point + lifecycle  [B]  ✅REAL (PV/PVC side)
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# EFS is a shared network file system (NFS) that many pods across many nodes can mount at the
# same time (`ReadWriteMany`). You need one mount target per AZ (the network door into the file
# system) and optionally an access point (a forced POSIX user + root directory per app).
#
# ── 2. Where it sits ──
# L3 → L4. Depends on: VPC/private subnets (R9), SG for NFS (R10), KMS (R18), the EFS CSI driver
# (R45). Consumed by: PersistentVolumes (R47).
# Whirlpool: ✅REAL on the Kubernetes side — `Helm/pvc/<env>/` holds `PersistentVolume` +
# `PersistentVolumeClaim` manifests that use `csi: driver: efs.csi.aws.com`, `accessModes:
# [ReadWriteMany]`, `persistentVolumeReclaimPolicy: Retain`, `storageClassName: efs`. The file
# system itself was created elsewhere.
#
# The ✅REAL consumption side (Kubernetes, shape from `Helm/pvc/<env>/`, with identifiers removed):
#
# [yaml — illustration from the notes, NOT applied by this module]
#   apiVersion: v1
#   kind: PersistentVolume
#   metadata:
#     name: efs-pv
#   spec:
#     capacity: { storage: 10Gi }          # required by the API but NOT enforced by EFS
#     accessModes: [ReadWriteMany]
#     persistentVolumeReclaimPolicy: Retain
#     storageClassName: efs
#     csi:
#       driver: efs.csi.aws.com
#       volumeHandle: fs-<FILE_SYSTEM_ID>
#
# CFN type names: `AWS::EFS::FileSystem`, `AWS::EFS::MountTarget`, `AWS::EFS::AccessPoint`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `creation_token`
#       what it does: Idempotency token
#       why it matters: Re-running create with the same token returns the same file system
#   ▸ `encrypted` + `kms_key_id`
#       what it does: At-rest encryption
#       why it matters: Create-time only
#   ▸ `throughput_mode = "elastic"`
#       what it does: Throughput scales automatically
#       why it matters: `bursting` can throttle under sustained load
#   ▸ `lifecycle_policy`
#       what it does: Move cold files to cheaper IA storage
#       why it matters: Big cost cut for rarely-read data
#   ▸ `aws_efs_mount_target` per subnet
#       what it does: The NFS endpoint in that AZ
#       why it matters: A pod in an AZ with no mount target cannot mount — the classic EFS timeout
#   ▸ `security_groups` (TCP 2049)
#       what it does: NFS firewall
#       why it matters: Without port 2049 open from nodes, mounts hang
#   ▸ `aws_efs_access_point`
#       what it does: Forces a POSIX user + root dir
#       why it matters: Lets multiple apps share one FS with isolation
#   ▸ `aws_efs_backup_policy`
#       what it does: Automatic AWS Backup
#       why it matters: Off by default
#
# ── 7. How it connects ──
# `EFS → mount target (per AZ) ← node SG :2049 ← EFS CSI driver ← PV (volumeHandle=fs-…) ← PVC ←
# pod`. If out of order: the PV references a file system that does not exist → pod stuck
# `ContainerCreating` with a mount timeout.
#
# ── 8. Must-know box ──
# • Skeleton: file system (encrypted, throughput mode) · mount target per AZ · SG allowing 2049 ·
#   access point · (K8s) CSI driver + PV/PVC.
# • Gotchas: one mount target per AZ or pods in that AZ cannot mount; PV `capacity` is not enforced;
#   `Retain` means deleting the PVC leaves the data and the PV `Released` (needs manual cleanup);
#   `ReadWriteMany` is EFS's strength, EBS is single-attach; ✅REAL: the committed PV files in
#   `Helm/pvc/` are `kubectl get -o yaml` dumps containing live `status`/`uid` — re-applying them is
#   fragile (see K8s notes).
# • Interview angle: `Iac.md` §Q-resources ("EFS mount targets per AZ").
#
# # L3 — Compute & integration
