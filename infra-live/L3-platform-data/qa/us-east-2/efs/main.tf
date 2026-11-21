# ─── LEAF ── L3-platform-data/qa/us-east-2/efs
# one leaf = one state = one pipeline unit = one owner (platform-team). Backend + provider + ONE pinned module call.
# module   : L3-platform-data/efs   (resource blueprint R31)
# upstream : read ONLY through the SSM contract (never another layer's tfstate) — depends on: vpc, security-groups, kms

terraform {
  required_version = ">= 1.10"
  backend "s3" {
    bucket       = "acme-tfstate-TOOLING_ACCOUNT"
    key          = "L3-platform-data/qa/us-east-2/efs/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-2"
  default_tags {
    tags = {
      Environment        = "qa"
      ManagedBy          = "terraform"
      Layer              = "L3"
      Owner              = "platform-team"
      Application        = "acme-platform"
      CostCenter         = "CC-3000"
      DataClassification = "confidential"
      Repo               = "infra-live"
    }
  }
}

# ── upstream values: the SSM contract (written by the producing layer's own apply) ──
data "aws_ssm_parameter" "kms_key_arn" {
  name = "/acme/qa/security/kms_key_arn"
}
data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/acme/qa/network/private_subnet_ids"
}
data "aws_ssm_parameter" "sg_efs_id" {
  name = "/acme/qa/network/sg_efs_id"
}

module "efs" {
  source = "git::https://github.com/sanketire45/Terraform-Iac.git//infra-modules/L3-platform-data/efs?ref=v1.4.0-rc.1"

  org                = "acme"
  env                = "qa"
  region             = "us-east-2"
  kms_key_arn        = data.aws_ssm_parameter.kms_key_arn.value
  private_subnet_ids = split(",", data.aws_ssm_parameter.private_subnet_ids.value)
  sg_efs_id          = data.aws_ssm_parameter.sg_efs_id.value
}

# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — how to read this leaf  (notes: §2.3 state, §2.5 layout, §2.6 trust chain, §2.9 SSM contract)
# ═══════════════════════════════════════════════════════════════════════
#
# What this leaf deploys: module efs (L3-platform-data) — vpc, security-groups, kms comes before it; RWX volumes for pods come after.
#
# ── terraform { backend "s3" } ──
#   bucket       the state bucket created once by tfstate-backend (R1), living in TOOLING_ACCOUNT — separate from the
#                accounts it describes, so a compromised workload account cannot rewrite its own history.
#   key          = "L3-platform-data/qa/us-east-2/efs/terraform.tfstate"
#                The key IS this leaf's path: one state per layer · env · region · component. The state file is therefore
#                also the LOCK scope, the BLAST-RADIUS boundary and the OWNERSHIP boundary (CODEOWNERS maps the folder).
#   encrypt      state is plain-text JSON that may hold secrets → encrypted at rest with S3 own keys (SSE-S3; no KMS key to manage).
#   use_lockfile S3-native locking (Terraform ≥ 1.10): a .tflock object next to the state. No DynamoDB table needed.
#   required_version ">= 1.10" refuses an old CLI that does not understand use_lockfile.
#
# ── provider "aws" ──
#   region       where this leaf creates things (the state bucket region above is independent of it).
#   (no assume_role)  Whirlpool style: this provider uses the AWS session that pipelines/ci/assume_role.sh exported for this environment
#                (account + role come from pipelines/config/<scope>-config.txt), so there is nothing to assume here.
#   default_tags every resource created by this leaf gets the mandatory tags — Environment / ManagedBy / Layer / Owner / Application /
#                CostCenter / DataClassification / Repo (policy/require_tags.rego fails the plan if one is missing) — cost allocation,
#                drift triage and the "who do I page" question are answered by tags alone.
#
# ── data "aws_ssm_parameter" — the cross-layer contract (R20) ──
#   Path is /<org>/<env>/<layer>/<key>. The PRODUCING layer writes it at the end of its own apply (see PUBLISH in its module);
#   THIS leaf only reads it. Lists are stored as comma-joined StringList → consumed with split(",", …). Why not remote_state?
#   it would couple this leaf to another layer's state file (access, schema, tool). SSM works for Terraform, CloudFormation and CI alike.
#   Keys read here:
#     /acme/qa/security/kms_key_arn
#     /acme/qa/network/private_subnet_ids
#     /acme/qa/network/sg_efs_id
#
# ── module "..." { source = "git::…//<layer>/<module>?ref=…" } ──
#   source  a git URL into the modules repo, "//" selects the sub-directory, ?ref pins the version. Same template everywhere;
#   this env pins v1.4.0-rc.1: dev floats on main, qa/stage on a release-candidate tag, prod on an EXACT released tag.
#   Promotion = changing this one ref (PR → dev → qa → stage → prod). Nothing else differs between environments except VALUES.
#   Inputs:
#     org / env / region          naming prefix, environment label, primary region (every module takes these three)
#     kms_key_arn                 from SSM qa/security/kms_key_arn (published by module kms)
#     private_subnet_ids          from SSM qa/network/private_subnet_ids (published by module vpc)
#     sg_efs_id                   from SSM qa/network/sg_efs_id (published by module security-groups)
#
# Env-specific BEHAVIOUR that is not an input (e.g. prod = deletion protection, 3 DB instances, private-only endpoint) is
# derived from env == "prod" INSIDE the module — read the module's code and its EXPLAINED block for the why.
# Order of operations: this leaf can only apply after its upstream keys exist (deploy bottom-up, destroy top-down).
