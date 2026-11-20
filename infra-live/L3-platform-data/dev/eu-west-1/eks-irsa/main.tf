# ─── LEAF ── L3-platform-data/dev/eu-west-1/eks-irsa
# one leaf = one state = one pipeline unit = one owner (platform-team). Backend + provider + ONE pinned module call.
# module   : L3-platform-data/eks-irsa   (resource blueprint R40)
# upstream : read ONLY through the SSM contract (never another layer's tfstate) — depends on: eks-cluster (OIDC issuer must exist)

terraform {
  required_version = ">= 1.10"
  backend "s3" {
    bucket       = "acme-tfstate-TOOLING_ACCOUNT"
    key          = "L3-platform-data/dev/eu-west-1/eks-irsa/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    kms_key_id   = "alias/tfstate"
    use_lockfile = true
  }
}

variable "external_id" {
  type      = string
  sensitive = true # sts:ExternalId the terraform-exec trust policy demands — injected by the pipeline as TF_VAR_external_id, never in git
}

provider "aws" {
  region = "eu-west-1"
  assume_role {
    role_arn    = "arn:aws:iam::DEV_ACCOUNT:role/terraform-exec"
    external_id = var.external_id
  }
  default_tags {
    tags = {
      Environment        = "dev"
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
data "aws_ssm_parameter" "cluster_oidc_issuer_url" {
  name = "/acme/dev/platform/cluster_oidc_issuer_url"
}

module "eks_irsa" {
  source = "git::https://git.example.com/infra-modules.git//L3-platform-data/eks-irsa?ref=main"

  org                     = "acme"
  env                     = "dev"
  region                  = "eu-west-1"
  account_id              = "DEV_ACCOUNT"
  cluster_oidc_issuer_url = data.aws_ssm_parameter.cluster_oidc_issuer_url.value
  prefix                  = "acme"
  lbc_policy_arn          = "arn:aws:iam::DEV_ACCOUNT:policy/AWSLoadBalancerControllerIAMPolicy"
}

# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — how to read this leaf  (notes: §2.3 state, §2.5 layout, §2.6 trust chain, §2.9 SSM contract)
# ═══════════════════════════════════════════════════════════════════════
#
# What this leaf deploys: module eks-irsa (L3-platform-data) — eks-cluster (OIDC issuer must exist) comes before it; every workload needing AWS access come after.
#
# ── terraform { backend "s3" } ──
#   bucket       the state bucket created once by tfstate-backend (R1), living in TOOLING_ACCOUNT — separate from the
#                accounts it describes, so a compromised workload account cannot rewrite its own history.
#   key          = "L3-platform-data/dev/eu-west-1/eks-irsa/terraform.tfstate"
#                The key IS this leaf's path: one state per layer · env · region · component. The state file is therefore
#                also the LOCK scope, the BLAST-RADIUS boundary and the OWNERSHIP boundary (CODEOWNERS maps the folder).
#   encrypt / kms_key_id   state is plain-text JSON that may hold secrets → SSE-KMS with alias/tfstate.
#   use_lockfile S3-native locking (Terraform ≥ 1.10): a .tflock object next to the state. No DynamoDB table needed.
#   required_version ">= 1.10" refuses an old CLI that does not understand use_lockfile.
#
# ── provider "aws" ──
#   region       where this leaf creates things (the state bucket region above is independent of it).
#   assume_role  the trust chain with NO long-lived keys: CI OIDC token → ci-bootstrap (TOOLING) → terraform-exec in DEV_ACCOUNT.
#                Each target account only trusts ci-bootstrap (+ ExternalId), so a leaf can only ever touch its own account.
#   external_id  the shared secret the terraform-exec trust policy demands (sts:ExternalId). A sensitive variable: the pipeline injects
#                TF_VAR_external_id from its secret store, so it is never in git. (Every aliased provider in a leaf carries it too.)
#   default_tags every resource created by this leaf gets the mandatory tags — Environment / ManagedBy / Layer / Owner / Application /
#                CostCenter / DataClassification / Repo (policy/require_tags.rego fails the plan if one is missing) — cost allocation,
#                drift triage and the "who do I page" question are answered by tags alone.
#
# ── data "aws_ssm_parameter" — the cross-layer contract (R20) ──
#   Path is /<org>/<env>/<layer>/<key>. The PRODUCING layer writes it at the end of its own apply (see PUBLISH in its module);
#   THIS leaf only reads it. Lists are stored as comma-joined StringList → consumed with split(",", …). Why not remote_state?
#   it would couple this leaf to another layer's state file (access, schema, tool). SSM works for Terraform, CloudFormation and CI alike.
#   Keys read here:
#     /acme/dev/platform/cluster_oidc_issuer_url
#
# ── module "..." { source = "git::…//<layer>/<module>?ref=…" } ──
#   source  a git URL into the modules repo, "//" selects the sub-directory, ?ref pins the version. Same template everywhere;
#   this env pins main: dev floats on main, qa/stage on a release-candidate tag, prod on an EXACT released tag.
#   Promotion = changing this one ref (PR → dev → qa → stage → prod). Nothing else differs between environments except VALUES.
#   Inputs:
#     org / env / region          naming prefix, environment label, primary region (every module takes these three)
#     account_id                  literal for this environment (account id)
#     cluster_oidc_issuer_url     from SSM dev/platform/cluster_oidc_issuer_url (published by module eks-cluster)
#     prefix                      literal for this environment (prefix)
#     lbc_policy_arn              literal for this environment (lbc policy arn)
#
# Env-specific BEHAVIOUR that is not an input (e.g. prod = deletion protection, 3 DB instances, private-only endpoint) is
# derived from env == "prod" INSIDE the module — read the module's code and its EXPLAINED block for the why.
# Order of operations: this leaf can only apply after its upstream keys exist (deploy bottom-up, destroy top-down).
