# ════════════════════════════════════════════════════════════════════════
#  MODULE : ecr
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R32 [Tier A]  →  Iac_blueprint_masterclass.md, "R32"
#  Depends on : kms
#  Consumed by: every pipeline (push) + every cluster (pull)
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

variable "kms_key_arn" {
  type        = string
  description = "Kms key arn — read from the SSM contract (/<org>/<env>/security/kms_key_arn, published by kms)"
}

variable "service_names" {
  type        = list(string)
  description = "One ECR repository is created per name"
}

resource "aws_ecr_repository" "svc" {
  for_each             = toset(var.service_names) # one repo per microservice
  name                 = "${var.org}/${each.value}"
  image_tag_mutability = "IMMUTABLE" # a tag can never be overwritten
  force_delete         = false
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 30 tagged images" # ≈ ECR_REPO_EXPIRY_DAYS in spirit
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}

# Cross-account pull: the shared account's repo lets dev/qa/stage/prod pull  (≈ ECR_CONSUMER_ARNs)
data "aws_iam_policy_document" "pull" {
  statement {
    sid     = "AllowCrossAccountPull"
    effect  = "Allow"
    actions = ["ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability"]
    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::DEV_ACCOUNT:root", "arn:aws:iam::QA_ACCOUNT:root",
      "arn:aws:iam::STAGE_ACCOUNT:root", "arn:aws:iam::PROD_ACCOUNT:root"]
    }
  }
}
resource "aws_ecr_repository_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name
  policy     = data.aws_iam_policy_document.pull.json
}

# Optional: replicate images to a DR region
resource "aws_ecr_replication_configuration" "dr" {
  replication_configuration {
    rule {
      destination {
        region      = "us-east-1"
        registry_id = data.aws_caller_identity.current.account_id
      }
    }
  }
}
data "aws_caller_identity" "current" {}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R32 — ECR repository + lifecycle policy + cross-account pull + scan-on-push  [A]  ✅REAL (via config + Service Catalog)
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# ECR is AWS's private Docker registry. Every microservice image is pushed here by CI and
# pulled by the cluster. A production repository is never just a name: it needs immutable tags
# (so a tag always means the same image), a lifecycle policy (so old images do not pile up and
# cost money), scan-on-push, and a policy letting other accounts pull.
#
# ── 2. Where it sits ──
# • Layer L3. Depends on: KMS (optional, R18). Consumed by: CI (push), EKS nodes/pods (pull — dev,
#   qa, stage, prod accounts pull from the shared account).
# • Whirlpool: ✅REAL through config, not a template. `config/<env>-config.txt` carries
#   `ECR_REPO_URL`, `ECR_REPO_EXPIRY_DAYS` and `ECR_CONSUMER_ARNs`, and `ECR_PRODUCT_ID` /
#   `PROV_ARTIFACT_ID` — the repository was provisioned as an AWS Service Catalog product
#   (`getSVCProductCreateOrUpdateCMD()` in the shared Groovy lib). The product's template itself is
#   not in this repo, so there is no CFN block here (and none is invented).
#
# │ The three config keys are the whole design in miniature:
# │ `…_EXPIRY_DAYS` = the lifecycle policy; `…_CONSUMER_ARNs` = the cross-account pull policy;
# │ `…_PRODUCT_ID` = self-service provisioning through Service Catalog (R70).
#
# CFN type names (for recognition): `AWS::ECR::Repository`, `AWS::ECR::ReplicationConfiguration`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `for_each = toset(var.service_names)`
#       what it does: One repo per service
#       why it matters: 130+ services = one list, not 130 resource blocks
#   ▸ `image_tag_mutability = "IMMUTABLE"`
#       what it does: A pushed tag cannot be reused
#       why it matters: Without it, `latest`/`1.4.2` can silently change under a running deployment
#           — reproducibility gone
#   ▸ `scan_on_push`
#       what it does: Basic vulnerability scan on every push
#       why it matters: Free signal; enhanced scanning (Inspector) is a step up
#   ▸ `encryption_configuration`
#       what it does: KMS vs default AES256
#       why it matters: A CMK adds key-level access control
#   ▸ `force_delete = false`
#       what it does: Refuse to delete a repo that has images
#       why it matters: Protects against `destroy` wiping the registry
#   ▸ `aws_ecr_lifecycle_policy`
#       what it does: Auto-expire images by age/count
#       why it matters: Without it, the registry grows forever and so does the bill
#   ▸ `rulePriority`
#       what it does: Evaluation order (lowest first)
#       why it matters: The first matching rule decides
#   ▸ `tagStatus` / `countType` / `countNumber`
#       what it does: What to expire and when
#       why it matters: `untagged` cleanup removes orphaned layers from rebuilds
#   ▸ `aws_ecr_repository_policy` + `principals`
#       what it does: Cross-account pull permission
#       why it matters: ECR needs the policy on the *repo*, and the pulling account needs IAM
#           permission too — both sides
#   ▸ `ecr:GetDownloadUrlForLayer`, `BatchGetImage`, `BatchCheckLayerAvailability`
#       what it does: The three actions a pull needs
#       why it matters: Missing one → `ImagePullBackOff` with an auth-looking error
#   ▸ `aws_ecr_replication_configuration`
#       what it does: Copy images to another region
#       why it matters: DR: the cluster in region B can pull locally
#
# ── 7. How it connects ──
# • Consumes: KMS key; the account IDs of consumers (aliases here).
# • Produces: repo URL → CI (`docker push`), Helm `image.repository`, EKS node role (needs
#   `ecr:GetAuthorizationToken` + the pull actions).
# • `CI (assume SHARED role) → push → ECR (SHARED_ACCOUNT) ← pull ← EKS nodes in DEV/QA/STAGE/PROD`
# • If out of order: a repository must exist before CI's first push; a cross-account policy naming
#   an account that is not in the Organization is rejected only if `aws:PrincipalOrgID` conditions
#   are used. For private subnets, ECR pulls need the ECR VPC endpoints + S3 gateway (R12) or a NAT.
#
# ── 8. Must-know box ──
# • Skeleton: `aws_ecr_repository` (`IMMUTABLE`, `scan_on_push`) · lifecycle policy · repository
#   policy for consumers · (replication).
# • Gotchas:
#   • ✅REAL: the lifecycle (`ECR_REPO_EXPIRY_DAYS`) and consumers (`ECR_CONSUMER_ARNs`) were per-env
#     config values — 8 config files to keep in sync.
#   • Immutable tags + CI that re-pushes the same tag = push failures — design CI to produce unique
#     tags (✅REAL: the `JenkinsfileAutoTagGenration*` pipelines).
#   • Pulling from private subnets needs `ecr.api` + `ecr.dkr` + the S3 gateway endpoint.
#   • ECR auth tokens expire after 12 hours — `aws ecr get-login-password` per CI run.
#   • Cross-account pull needs permission on both the repo policy and the puller's IAM role.
# • CFN vs TF difference: CFN `LifecyclePolicy: { LifecyclePolicyText: … }` is a JSON string inside
#   the resource; Terraform splits the policy into `aws_ecr_lifecycle_policy`.
# • Interview angle: `Iac.md` §Q-resources ("what makes ECR pulls fail from a private subnet"),
#   §Q-whirlpool.
