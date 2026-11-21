# ─── LEAF ── L3-platform-data/dev/us-east-2/rds-mysql
# one leaf = one state = one pipeline unit. Backend + provider + ONE module call.
# module   : L3-platform-data/rds-mysql   (small test MySQL on the default VPC)
# upstream : none

terraform {
  required_version = ">= 1.10"
  backend "s3" {
    bucket       = "acme-tfstate-TOOLING_ACCOUNT"
    key          = "L3-platform-data/dev/us-east-2/rds-mysql/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-2"
  default_tags {
    tags = {
      Environment        = "dev"
      ManagedBy          = "terraform"
      Layer              = "L3"
      Owner              = "platform-team"
      Application        = "acme-platform"
      CostCenter         = "CC-3000"
      DataClassification = "internal"
      Repo               = "infra-live"
    }
  }
}

module "rds_mysql" {
  source = "git::https://github.com/sanketire45/Terraform-Iac.git//infra-modules/L3-platform-data/rds-mysql?ref=main"

  org    = "acme"
  env    = "dev"
  region = "us-east-2"
}

# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — how to read this leaf
# ═══════════════════════════════════════════════════════════════════════
#   backend "s3"   where THIS leaf keeps its state: bucket acme-tfstate-<state account>, key = the leaf's own path.
#                  The account placeholder in the bucket name is replaced by the pipeline with the state-account id from pipelines/config/dev-config.txt.
#   provider "aws" region + the mandatory tags every resource gets. No assume_role: the pipeline already exported the
#                  terraform-exec session for this environment.
#   module         source = a git URL into this repo's infra-modules folder; "//" picks the sub-directory, ?ref=main the version.
#                  In the pipeline the source is swapped for the local folder (LOCAL_MODULES_ALL=true).
#                  Values passed in: only org/env/region — the module defaults (db.t4g.micro, 20 GB, MySQL 8.0) are the cheap test setup.
