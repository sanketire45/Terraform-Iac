# ════════════════════════════════════════════════════════════════════════
#  MODULE : rds-mysql   (small, cheap, easy-to-delete test database)
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Depends on : nothing (uses the account's DEFAULT VPC — no network layer needed)
#  Inputs  : variables below
#  Outputs : published to SSM /<org>/<env>/data/<key>  (see PUBLISH below the code)
#  The explanation of every block is in the comment at the END of this file.
# ════════════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "org" {
  type        = string
  description = "Organisation prefix used in names and the SSM contract path (e.g. acme)"
}

variable "env" {
  type        = string
  description = "Environment label (dev | qa | stage | prod …)"
}

variable "region" {
  type        = string
  description = "Primary AWS region of this stack"
}

variable "instance_class" {
  type        = string
  default     = "db.t4g.micro"
  description = "Smallest/cheapest instance class (free-tier eligible on new accounts)"
}

variable "allocated_storage" {
  type        = number
  default     = 20
  description = "Disk size in GB (20 is the minimum for gp3)"
}

variable "engine_version" {
  type        = string
  default     = "8.0"
  description = "MySQL major.minor; AWS picks the newest patch release"
}

variable "db_name" {
  type        = string
  default     = "appdb"
  description = "Name of the first database created inside the instance"
}

variable "username" {
  type        = string
  default     = "admin"
  description = "Master user name"
}

variable "storage_encrypted" {
  type        = bool
  default     = false
  description = "Encrypt the disk. Test default is false (no KMS key involved); turn on for anything real."
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "random_password" "master" {
  length  = 24
  special = false # MySQL rejects / @ " and space; letters+digits are always safe
}

resource "aws_security_group" "mysql" {
  name        = "${var.env}-mysql"
  description = "MySQL from inside the VPC only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "MySQL from the VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }
}

resource "aws_db_subnet_group" "mysql" {
  name       = "${var.env}-mysql"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "mysql" {
  identifier        = "${var.env}-mysql"
  engine            = "mysql"
  engine_version    = var.engine_version
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = var.storage_encrypted

  db_name  = var.db_name
  username = var.username
  password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.mysql.name
  vpc_security_group_ids = [aws_security_group.mysql.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 0 # no automated backups: nothing extra to pay for or clean up
  auto_minor_version_upgrade = true
  apply_immediately          = true

  skip_final_snapshot = true # destroy = gone, no snapshot left behind
  deletion_protection = false

  lifecycle { prevent_destroy = false }
}

# ════════════════ PUBLISH — the cross-layer contract (R20) ════════════════
# Every value another layer needs is written to SSM Parameter Store at /<org>/<env>/data/<key>.
# The password is NOT published (it lives only in this leaf's encrypted state file).
locals {
  ssm_prefix = "/${var.org}/${var.env}/data"
  contract_strings = merge(
    {
      mysql_endpoint = aws_db_instance.mysql.address
      mysql_port     = tostring(aws_db_instance.mysql.port)
      mysql_db_name  = aws_db_instance.mysql.db_name
    },
  )
}
resource "aws_ssm_parameter" "contract_string" {
  for_each = local.contract_strings
  name     = "${local.ssm_prefix}/${each.key}"
  type     = "String"
  value    = each.value
}
output "contract" {
  description = "Everything this module publishes to SSM (also readable via the SSM path)"
  value       = local.contract_strings
}

# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED
# ═══════════════════════════════════════════════════════════════════════
#   data "aws_vpc" "default" / "aws_subnets"   reads the account's default VPC and its subnets (one per AZ). The DB needs a subnet
#        group spanning at least two AZs; the default VPC already has them, so no network layer is needed for this test.
#   random_password        generates the master password once and keeps it in state; it only changes if the resource is replaced.
#        special = false keeps characters MySQL accepts without escaping. It is never printed or published.
#   aws_security_group     the firewall of the DB: port 3306 only from addresses inside the VPC. Nothing from the internet.
#   aws_db_subnet_group    tells RDS which subnets it may place the instance in.
#   aws_db_instance
#        instance_class    db.t4g.micro = the smallest Graviton class, about a cent or two per hour (free-tier eligible).
#        storage gp3 20GB  the minimum disk. storage_encrypted false for the test (no KMS key); real databases turn it on.
#        publicly_accessible false   no public IP — it can only be reached from inside the VPC.
#        backup_retention_period 0   automated backups off: nothing to pay for, nothing left after delete.
#        skip_final_snapshot true    destroy removes it completely (a real DB keeps a final snapshot).
#        deletion_protection false   so terraform destroy / the console can delete it.
#        apply_immediately          changes apply now, not at the next maintenance window.
#   PUBLISH                writes endpoint, port and database name to /<org>/<env>/data/* so other leaves could read them.
#   Creating takes ~5-10 minutes; deleting takes ~5 minutes. Cost while it exists: roughly $0.02/hour + $2/month for the disk.
