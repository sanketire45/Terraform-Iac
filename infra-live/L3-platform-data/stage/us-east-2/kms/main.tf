# ─── LEAF ── L3-platform-data/stage/us-east-2/kms
# one leaf = one state = one pipeline unit = one owner (platform-team). Backend + provider + ONE pinned module call.
# module   : L3-platform-data/kms   (resource blueprint R18)
# upstream : read ONLY through the SSM contract (never another layer's tfstate) — depends on: (none - first thing in the layer)

terraform {
  required_version = ">= 1.10"
  backend "s3" {
    bucket       = "acme-tfstate-TOOLING_ACCOUNT"
    key          = "L3-platform-data/stage/us-east-2/kms/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-2"
  default_tags {
    tags = {
      Environment        = "stage"
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

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = {
      Environment        = "stage"
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

module "kms" {
  source = "git::https://github.com/sanketire45/Terraform-Iac.git//infra-modules/L3-platform-data/kms?ref=v1.4.0-rc.1"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  org                = "acme"
  env                = "stage"
  region             = "us-east-2"
  key_admin_role_arn = "arn:aws:iam::STAGE_ACCOUNT:role/PlatformAdmin"
  key_user_role_arns = ["arn:aws:iam::STAGE_ACCOUNT:role/stage-app"]
}

# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — how to read this leaf  (notes: §2.3 state, §2.5 layout, §2.6 trust chain, §2.9 SSM contract)
# ═══════════════════════════════════════════════════════════════════════
#
# What this leaf deploys: module kms (L3-platform-data) — (none - first thing in the layer) comes before it; secrets, s3, rds, msk, eks, ebs come after.
#
# ── terraform { backend "s3" } ──
#   bucket       the state bucket created once by tfstate-backend (R1), living in TOOLING_ACCOUNT — separate from the
#                accounts it describes, so a compromised workload account cannot rewrite its own history.
#   key          = "L3-platform-data/stage/us-east-2/kms/terraform.tfstate"
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
#   alias "us_east_1"  a second provider instance: CloudFront certificates and CLOUDFRONT-scope WAF MUST be created in us-east-1.
#
# ── module "..." { source = "git::…//<layer>/<module>?ref=…" } ──
#   source  a git URL into the modules repo, "//" selects the sub-directory, ?ref pins the version. Same template everywhere;
#   this env pins v1.4.0-rc.1: dev floats on main, qa/stage on a release-candidate tag, prod on an EXACT released tag.
#   Promotion = changing this one ref (PR → dev → qa → stage → prod). Nothing else differs between environments except VALUES.
#   providers  hands the aliased provider instances to the module (they must match its configuration_aliases).
#   Inputs:
#     org / env / region          naming prefix, environment label, primary region (every module takes these three)
#     key_admin_role_arn          literal for this environment (key admin role arn)
#     key_user_role_arns          literal for this environment (key user role arns)
#
# Env-specific BEHAVIOUR that is not an input (e.g. prod = deletion protection, 3 DB instances, private-only endpoint) is
# derived from env == "prod" INSIDE the module — read the module's code and its EXPLAINED block for the why.
# Order of operations: this leaf can only apply after its upstream keys exist (deploy bottom-up, destroy top-down).
