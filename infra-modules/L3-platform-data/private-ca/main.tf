# ════════════════════════════════════════════════════════════════════════
#  MODULE : private-ca
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R23 [Tier B]  →  Iac_blueprint_masterclass.md, "R23"
#  Depends on : kms
#  Consumed by: internal mTLS (MSK, mesh)
#  Inputs  : variables below (cross-layer ones are fed by the live leaf from the SSM contract)
#  Outputs : published to SSM /<org>/<env>/security/<key>  (see PUBLISH below the code)
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

variable "crl_bucket_name" {
  type        = string
  description = "S3 bucket that serves the Private CA certificate revocation list"
}

resource "aws_acmpca_certificate_authority" "root" {
  type = "ROOT"
  certificate_authority_configuration {
    key_algorithm     = "RSA_4096"
    signing_algorithm = "SHA512WITHRSA"
    subject {
      common_name  = "internal-root-ca"
      organization = "<company>"
    }
  }
  revocation_configuration {
    crl_configuration {
      enabled            = true
      expiration_in_days = 7
      s3_bucket_name     = var.crl_bucket_name
    }
  }
  permanent_deletion_time_in_days = 30
}

# Self-sign the root, then install it
resource "aws_acmpca_certificate" "root" {
  certificate_authority_arn   = aws_acmpca_certificate_authority.root.arn
  certificate_signing_request = aws_acmpca_certificate_authority.root.certificate_signing_request
  signing_algorithm           = "SHA512WITHRSA"
  template_arn                = "arn:aws:acm-pca:::template/RootCACertificate/V1"
  validity {
    type  = "YEARS"
    value = 10
  }
}
resource "aws_acmpca_certificate_authority_certificate" "root" {
  certificate_authority_arn = aws_acmpca_certificate_authority.root.arn
  certificate               = aws_acmpca_certificate.root.certificate
  certificate_chain         = aws_acmpca_certificate.root.certificate_chain
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/security/<key>.
# Consumers (the live leaves of later layers) read it with `data "aws_ssm_parameter"` — never another layer's tfstate.
locals {
  ssm_prefix = "/${var.org}/${var.env}/security"
  contract_strings = merge(
    {
      private_ca_arn = aws_acmpca_certificate_authority.root.arn
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
# EXPLAINED — R23 — ACM Private CA (internal mTLS)  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# A private certificate authority that issues certificates for *internal* use — services
# proving who they are to each other (mutual TLS). Relevant here because MSK client
# authentication uses mutual TLS: clients present a certificate signed by a CA the cluster trusts.
#
# ── 2. Where it sits ──
# L3. Depends on: KMS (optional), S3 (CRL). Consumed by: MSK (R30), service meshes, internal ALBs.
# Whirlpool: ✅REAL *context* — MSK clients use keystore/truststore material (see R19); the CA that
# issued it is not in this repo. 🟡CONFIRM whether it was ACM PCA.
#
# CFN type names: `AWS::ACMPCA::CertificateAuthority`, `AWS::ACMPCA::Certificate`,
# `AWS::ACMPCA::CertificateAuthorityActivation`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `type = "ROOT"` / `"SUBORDINATE"`
#       what it does: Root signs itself; a subordinate is signed by another CA
#       why it matters: Production uses a root + subordinate hierarchy; keep the root offline-like
#   ▸ `key_algorithm`, `signing_algorithm`
#       what it does: Crypto strength
#       why it matters: Set once; changing means a new CA
#   ▸ `crl_configuration`
#       what it does: Publishes a revocation list to S3
#       why it matters: Without revocation you cannot cancel a leaked client cert
#   ▸ `permanent_deletion_time_in_days`
#       what it does: Grace period before the CA is really gone
#       why it matters: A private CA costs ~$400/month while it exists
#   ▸ `aws_acmpca_certificate_authority_certificate`
#       what it does: Installs the signed cert into the CA
#       why it matters: A CA is `PENDING_CERTIFICATE` and cannot issue until this runs
#
# ── 7. How it connects ──
# `Private CA → issues client certs → MSK trusts the CA (R30
# ClientAuthentication.Tls.CertificateAuthorityArnList)`. If out of order: MSK referencing a CA that
# is not `ACTIVE` fails.
#
# ── 8. Must-know box ──
# • Skeleton: CA (type, subject, algorithms, CRL) · CSR signed · certificate installed ·
#   (subordinate chain).
# • Gotchas: cost; a CA must be `ACTIVE`; revocation (CRL/OCSP) needs an S3 bucket policy for ACM
#   PCA; client certs are issued by *you* (`aws_acmpca_certificate`), they do not appear
#   automatically.
# • Interview angle: `Iac.md` §Q-resources.
#
# # L3 — Data tier
#
# │ Whirlpool context: the databases and the MSK cluster were owned by the platform team and
# │ are not in this repo (`rds-dynamodb`, `elasticache` are placeholder folders). Everything in
# │ this group except the MSK *client* values (R30) is 🧪IDEAL.
