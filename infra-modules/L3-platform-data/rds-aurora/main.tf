# ════════════════════════════════════════════════════════════════════════
#  MODULE : rds-aurora
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R24 [Tier A]  →  Iac_blueprint_masterclass.md, "R24"
#  Depends on : vpc, security-groups, kms, secrets
#  Consumed by: apps
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

variable "kms_key_arn" {
  type        = string
  description = "Kms key arn — read from the SSM contract (/<org>/<env>/security/kms_key_arn, published by kms)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

variable "role_rds_monitoring_arn" {
  type        = string
  description = "Role rds monitoring arn — read from the SSM contract (/<org>/<env>/iam/role_rds_monitoring_arn, published by iam-roles)"
}

variable "sg_db_id" {
  type        = string
  description = "Sg db id — read from the SSM contract (/<org>/<env>/network/sg_db_id, published by security-groups)"
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.env}-db"
  subnet_ids = var.private_subnet_ids # at least 2 AZs, PRIVATE subnets only
}

resource "aws_rds_cluster_parameter_group" "this" {
  name   = "${var.env}-aurora-pg15"
  family = "aurora-postgresql15"
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  } # log queries slower than 1s
}

resource "aws_rds_cluster" "this" {
  cluster_identifier            = "${var.env}-orders"
  engine                        = "aurora-postgresql"
  engine_version                = "15.4"
  database_name                 = "orders"
  master_username               = "dbadmin"
  manage_master_user_password   = true # RDS creates + rotates the password in Secrets Manager
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [var.sg_db_id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name

  storage_encrypted       = true
  kms_key_id              = var.kms_key_arn
  backup_retention_period = var.env == "prod" ? 35 : 7
  preferred_backup_window = "02:00-03:00"
  copy_tags_to_snapshot   = true

  deletion_protection       = var.env == "prod"
  skip_final_snapshot       = var.env != "prod"
  final_snapshot_identifier = var.env == "prod" ? "${var.env}-orders-final" : null

  enabled_cloudwatch_logs_exports     = ["postgresql"]
  iam_database_authentication_enabled = true
  apply_immediately                   = false # changes wait for the maintenance window

  lifecycle { prevent_destroy = false }
}

resource "aws_rds_cluster_instance" "this" {
  count                        = var.env == "prod" ? 3 : 1 # 1 writer + 2 readers in prod
  identifier                   = "${var.env}-orders-${count.index}"
  cluster_identifier           = aws_rds_cluster.this.id
  instance_class               = var.env == "prod" ? "db.r6g.xlarge" : "db.t4g.medium"
  engine                       = aws_rds_cluster.this.engine
  engine_version               = aws_rds_cluster.this.engine_version
  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn          = var.role_rds_monitoring_arn
  auto_minor_version_upgrade   = true
}

resource "aws_ssm_parameter" "db_endpoint" { # publish the contract (R20)
  name  = "/acme/${var.env}/data/orders_db_endpoint"
  type  = "String"
  value = aws_rds_cluster.this.endpoint
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R24 — RDS / Aurora cluster  [A]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# A managed relational database. RDS runs one instance; Aurora is AWS's cloud-built engine
# with a *cluster* — one writer, up to 15 readers sharing one storage layer. In IaC the interesting
# parts are not "create a DB" but the safety settings around it: encryption, backups, deletion
# protection, and not leaking the password.
#
# ── 2. Where it sits ──
# • Layer L3 (data). Hard-depends on: VPC + private subnets (R9), a DB SG (R10), a KMS key (R18), a
#   subnet group.
# • Consumed by: services (via a secret in R19 and an endpoint published to SSM R20).
#
# CFN type names (for recognition): `AWS::RDS::DBCluster`, `AWS::RDS::DBInstance`,
# `AWS::RDS::DBSubnetGroup`, `AWS::RDS::DBParameterGroup`, `AWS::RDS::DBClusterParameterGroup`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `aws_db_subnet_group`
#       what it does: Which subnets the DB may live in
#       why it matters: Needs ≥ 2 AZs; use private subnets only
#   ▸ `rds.force_ssl = 1`
#       what it does: Reject non-TLS connections
#       why it matters: Baseline security
#   ▸ `manage_master_user_password = true`
#       what it does: RDS creates and rotates the admin password in Secrets Manager
#       why it matters: The password never appears in your code or state — the modern answer to
#           "secrets in IaC"
#   ▸ `storage_encrypted` + `kms_key_id`
#       what it does: Encrypt at rest with your CMK
#       why it matters: Cannot be turned on later — you must restore from an encrypted snapshot copy
#   ▸ `backup_retention_period`
#       what it does: Days of automated backups (1–35)
#       why it matters: Point-in-time recovery window; `0` disables backups entirely
#   ▸ `deletion_protection`
#       what it does: Blocks delete via API/console
#       why it matters: Separate from Terraform's `prevent_destroy`; belt-and-braces
#   ▸ `skip_final_snapshot` / `final_snapshot_identifier`
#       what it does: Take a last snapshot on delete?
#       why it matters: `skip_final_snapshot = true` in prod = destroy the DB and keep nothing
#   ▸ `enabled_cloudwatch_logs_exports`
#       what it does: Ships engine logs to CloudWatch
#       why it matters: Logs are not exported by default
#   ▸ `iam_database_authentication_enabled`
#       what it does: Log in with an IAM token instead of a password
#       why it matters: Removes long-lived DB passwords for apps
#   ▸ `apply_immediately = false`
#       what it does: Changes wait for the maintenance window
#       why it matters: `true` can cause an unplanned restart
#   ▸ `aws_rds_cluster_instance` + `count`
#       what it does: One writer + N readers
#       why it matters: Here `count` is fine (a small fixed set); the first instance becomes the
#           writer
#   ▸ `performance_insights_enabled`, `monitoring_interval`
#       what it does: Query-level and OS-level metrics
#       why it matters: Essential for diagnosing slow queries
#   ▸ `lifecycle { prevent_destroy }`
#       what it does: Terraform-level brake
#       why it matters: Stops a refactor deleting the database
#
# ── 7. How it connects ──
# • Consumes: subnets/VPC (R9) via SSM, KMS (R18), SG (R10).
# • Produces: cluster endpoint (writer), reader endpoint, secret ARN → SSM (R20) → services; IAM
#   policies for `rds-db:connect`.
# • `app pod → (SG allows from app SG) → cluster writer endpoint · reads → reader endpoint`
# • If out of order: a DB created before its subnet group/SG/KMS key fails. Services that read the
#   endpoint before the DB exists fail their plan (useful).
#
# ── 8. Must-know box ──
# • Skeleton: subnet group · parameter group · cluster (engine, version,
#   `manage_master_user_password`, encryption, backups, `deletion_protection`, final snapshot) ·
#   instances · SG from app tier.
# • Gotchas:
#   • ⚠️ `skip_final_snapshot = true` + `deletion_protection = false` is how you lose a database.
#     Both are env-driven.
#   • Encryption cannot be added after creation.
#   • A major version change forces replacement of the parameter group family — plan it as a
#     migration.
#   • Changing `master_username` / `database_name` forces replacement.
#   • `apply_immediately = true` on prod → surprise reboot.
#   • Passwords passed as a variable end up in state — use `manage_master_user_password`.
#   • `count.index` ordering decides which instance is the writer at first creation.
# • CFN vs TF difference: CFN `DeletionPolicy: Snapshot` automatically snapshots on stack delete;
#   Terraform relies on `final_snapshot_identifier`. CFN `{{resolve:secretsmanager:…}}` can feed the
#   password without it entering the template.
# • Interview angle: `Iac.md` §Q-resources ("RDS `skip_final_snapshot` and deletion protection").
