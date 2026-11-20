# ════════════════════════════════════════════════════════════════════════
#  MODULE : secrets
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R19 [Tier A]  →  Iac_blueprint_masterclass.md, "R19"
#  Depends on : kms
#  Consumed by: pods via ESO, apps
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

variable "db_secret_id" {
  type        = string
  description = "Secrets Manager secret holding the DB master credentials (RDS-managed)"
}

variable "kms_key_arn" {
  type        = string
  description = "Kms key arn — read from the SSM contract (/<org>/<env>/security/kms_key_arn, published by kms)"
}

variable "lambda_rotate_arn" {
  type        = string
  description = "ARN of the Lambda that performs secret rotation"
}

# The CONTAINER — no value in code
resource "aws_secretsmanager_secret" "msk_keystore" {
  name                    = "${var.env}/msk/keystore"
  description             = "MSK client keystore + passwords"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30 # 0 = delete immediately (dangerous); 7–30 recommended
}

# The initial VALUE is set out-of-band (console / CLI / the app's own bootstrap) — NOT here.
# If you must seed a placeholder, ignore later changes so rotation does not look like drift:
resource "aws_secretsmanager_secret_version" "msk_keystore" {
  secret_id     = aws_secretsmanager_secret.msk_keystore.id
  secret_string = jsonencode({ keystore_password = "CHANGE_ME" }) # placeholder only
  lifecycle { ignore_changes = [secret_string] }                  # rotation/humans own the real value
}

# Rotation: a Lambda that knows how to change this secret (AWS provides templates for RDS)
resource "aws_secretsmanager_secret_rotation" "db" {
  secret_id           = var.db_secret_id
  rotation_lambda_arn = var.lambda_rotate_arn
  rotation_rules { automatically_after_days = 30 }
}

# Who may read it — a resource policy, scoped
data "aws_iam_policy_document" "read" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.msk_keystore.arn]
  }
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R19 — Secrets Manager secret + version + rotation  [A]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# Secrets Manager stores passwords, API keys and certificates, encrypts them with KMS, and
# can rotate them automatically. The point of IaC here is to create the *secret container*
# without ever putting the secret *value* in code or state.
#
# ── 2. Where it sits ──
# • Layer L3. Depends on: KMS key (R18). Consumed by: RDS (R24, can auto-manage its own password),
#   pods via External Secrets Operator (R48), Lambda (R56), MSK client credentials (R30).
# • Whirlpool: ❌ no Secrets Manager in the repo. The ✅REAL situation is the opposite — see the
#   anti-pattern below.
#
# The ✅REAL anti-pattern (and why this resource exists). The MSK client TLS material sits in
# `ground-layer-IAC/msk/values-key-<env>.yaml` (×7, one per env) as base64 in Helm values:
#
# [yaml — illustration from the notes, NOT applied by this module]
#   # Structure only — real values are credentials, not echoed
#   msk:
#     keystore_base64:   <base64-encoded keystore>     # contains a PRIVATE KEY
#     truststore_base64: <base64-encoded truststore>
#     truststore_password: <password>
#     keystore_password:   <password>
#     key_password:        <password>
#
# │ base64 is encoding, not encryption. Anyone with read access to the Git repo has the keys.
# │ The fix is a secret store: the value lives in Secrets Manager, Git holds only a *reference*.
#
# The correct consumption pattern for the cluster — an `ExternalSecret` (the External Secrets
# Operator, R48, reads Secrets Manager and creates the Kubernetes Secret):
#
# [yaml — illustration from the notes, NOT applied by this module]
#   apiVersion: external-secrets.io/v1beta1
#   kind: ExternalSecret
#   metadata:
#     name: msk-credentials
#     namespace: <app-namespace>
#   spec:
#     secretStoreRef: { name: aws-secrets-manager, kind: SecretStore }
#     target: { name: msk-credentials }
#     data:
#       - secretKey: keystore_base64
#         remoteRef: { key: prod/msk/keystore, property: keystore_base64 }
#       - secretKey: keystore_password
#         remoteRef: { key: prod/msk/keystore, property: keystore_password }
#
# CFN type names: `AWS::SecretsManager::Secret`, `AWS::SecretsManager::RotationSchedule`,
# `AWS::SecretsManager::ResourcePolicy`. In CFN, read one JSON key with
# `{{resolve:secretsmanager:prod/msk/keystore:SecretString:keystore_password}}`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `name`
#       what it does: Path-style secret name `env/service/name`
#       why it matters: Lets IAM policies scope by prefix (`prod/*`)
#   ▸ `kms_key_id`
#       what it does: Encrypts with *your* CMK
#       why it matters: Default key works but you cannot control access
#   ▸ `recovery_window_in_days`
#       what it does: Grace period before permanent delete
#       why it matters: `0` deletes at once — and you cannot reuse the name for the window otherwise
#   ▸ `aws_secretsmanager_secret_version.secret_string`
#       what it does: The value (as JSON for multiple fields)
#       why it matters: ⚠️ Whatever you put here is written to the state file in plaintext
#   ▸ `ignore_changes = [secret_string]`
#       what it does: Stops Terraform fighting rotation
#       why it matters: Without it every rotation shows up as drift and Terraform reverts it
#   ▸ `rotation_lambda_arn` + `automatically_after_days`
#       what it does: Schedules a rotation function
#       why it matters: Rotation needs the Lambda to reach the DB (VPC, SG)
#   ▸ `secretsmanager:GetSecretValue` on a specific ARN
#       what it does: Least-privilege read
#       why it matters: `Resource: "*"` lets a workload read every secret
#
# ── 7. How it connects ──
# `Secrets Manager → (ESO or direct SDK call) → pod / Lambda`. KMS key policy must allow the reader
# to decrypt as well as the secret's resource policy to allow GetSecretValue.
# If out of order: a secret referencing a CMK that does not exist fails; ESO syncing before the
# SecretStore/IRSA role exists leaves the `ExternalSecret` `SecretSyncedError`.
#
# ── 8. Must-know box ──
# • Skeleton: `aws_secretsmanager_secret` (name, KMS key, recovery window) · version with
#   `ignore_changes` · rotation (Lambda + days) · scoped read policy.
# • Gotchas:
#   • ⚠️ Putting the value in Terraform puts it in state. Create the container in IaC; set the value
#     out-of-band, or let the resource generate it (RDS `manage_master_user_password`).
#   • base64 ≠ encryption — never commit it (✅REAL anti-pattern above).
#   • Secrets Manager vs SSM SecureString: Secrets Manager = rotation + cross-account + higher cost
#     per secret; SSM SecureString = cheap, no native rotation.
#   • Deleted-secret name is blocked until the recovery window ends.
# • CFN vs TF difference: CFN's `{{resolve:secretsmanager:…}}` pulls the value at deploy time
#   without storing it in the template; Terraform reads via a `data` source (and then it lands in
#   state).
# • Interview angle: `Iac.md` §Q-operations ("secrets in IaC"), §Q-traps ("does `sensitive` encrypt
#   anything?").
