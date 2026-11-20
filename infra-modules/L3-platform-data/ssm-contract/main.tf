# ════════════════════════════════════════════════════════════════════════
#  MODULE : ssm-contract
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R20 [Tier B]  →  Iac_blueprint_masterclass.md, "R20"
#  Depends on : (every layer publishes)
#  Consumed by: downstream layers + pipelines (the cross-layer contract)
#  Inputs  : variables below (cross-layer ones are fed by the live leaf from the SSM contract)
#  Outputs : already publishes its own SSM parameters (see the code)
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

variable "api_key" {
  type        = string
  description = "Secret value stored as a SecureString (injected by the pipeline, never in git)"
  sensitive   = true
}

variable "kms_key_arn" {
  type        = string
  description = "Kms key arn — read from the SSM contract (/<org>/<env>/security/kms_key_arn, published by kms)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

variable "vpc_id" {
  type        = string
  description = "Vpc id — read from the SSM contract (/<org>/<env>/network/vpc_id, published by vpc)"
}

# String
resource "aws_ssm_parameter" "vpc_id" {
  name  = "/acme/${var.env}/network/vpc_id"
  type  = "String"
  value = var.vpc_id
  tags = {
    ManagedBy = "terraform",
    Layer     = "network"
  }
}
# StringList (comma-separated)
resource "aws_ssm_parameter" "private_subnets" {
  name  = "/acme/${var.env}/network/private_subnet_ids"
  type  = "StringList"
  value = join(",", var.private_subnet_ids)
}
# SecureString (encrypted) — the value is still in state, so only for low-sensitivity config
resource "aws_ssm_parameter" "api_url" {
  name   = "/acme/${var.env}/app/downstream_api_key"
  type   = "SecureString"
  key_id = var.kms_key_arn
  value  = var.api_key # ⚠️ ends up in state — prefer Secrets Manager for real secrets
}
# Consume
data "aws_ssm_parameter" "vpc_id" { name = "/acme/${var.env}/network/vpc_id" }


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R20 — SSM Parameter Store + the cross-layer contract pattern  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# Parameter Store is a free-to-cheap key/value store. In IaC it plays two roles: holding
# configuration (`/acme/prod/app/log_level`) and — more importantly — being the contract
# between layers: the network stack *publishes* the VPC ID, the edge stack *reads* it. (See §2.9.)
#
# ── 2. Where it sits ──
# L3, but read by every layer. Depends on: nothing. Consumed by: all stacks.
# Whirlpool: ✅REAL *usage* — `CLUSTER_NLB_SSM_KEY` appears in the config files and the Jenkinsfile
# reads it, so SSM was already in play for at least the NLB hand-off. 🟡CONFIRM how widely it was
# used.
#
# CFN: `AWS::SSM::Parameter` to publish; `Type: AWS::SSM::Parameter::Value<String>` or
# `{{resolve:ssm:/path}}` to read.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `name` (path)
#       what it does: Hierarchical key
#       why it matters: Path = permission boundary: IAM can allow `/acme/prod/network/*` for read
#           only
#   ▸ `type`
#       what it does: `String`, `StringList`, `SecureString`
#       why it matters: SecureString is KMS-encrypted at rest
#   ▸ `key_id`
#       what it does: The CMK for SecureString
#       why it matters: Default key is account-wide; a CMK scopes it
#   ▸ `value`
#       what it does: The stored data
#       why it matters: ⚠️ In Terraform state in plaintext, even for SecureString
#   ▸ `data "aws_ssm_parameter"`
#       what it does: Reads one parameter
#       why it matters: Reading a SecureString puts it in the consumer's state too
#
# ── 7. How it connects ──
# `producer stack → PutParameter → /acme/<env>/<layer>/<key> → consumer stack data source / CFN
# parameter type`.
# If out of order: the consumer's `data` read fails the plan if the parameter does not exist — which
# is a *useful* failure: it tells you the producing layer has not been deployed.
#
# ── 8. Must-know box ──
# • Skeleton: `aws_ssm_parameter` (name path, type, value) · `data "aws_ssm_parameter"` · naming
#   standard `/<org>/<env>/<layer>/<key>`.
# • Gotchas: parameter names are immutable (rename = replace); standard tier is 4 KB, advanced 8 KB;
#   throttle limits on `GetParameter` at scale — use `GetParametersByPath`; `String` values are
#   visible to anyone with read access.
# • Interview angle: `Iac.md` §Q-architecture ("how does the edge learn the subnet IDs?").
