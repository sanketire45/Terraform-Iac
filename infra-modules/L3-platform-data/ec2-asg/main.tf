# ════════════════════════════════════════════════════════════════════════
#  MODULE : ec2-asg
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R33 [Tier B]  →  Iac_blueprint_masterclass.md, "R33"
#  Depends on : vpc, iam-roles
#  Consumed by: legacy / non-K8s compute
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

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

variable "role_app_name" {
  type        = string
  description = "Role app name — read from the SSM contract (/<org>/<env>/iam/role_app_name, published by iam-roles)"
}

variable "sg_app_id" {
  type        = string
  description = "Sg app id — read from the SSM contract (/<org>/<env>/network/sg_app_id, published by security-groups)"
}

variable "vpc_id" {
  type        = string
  description = "Vpc id — read from the SSM contract (/<org>/<env>/network/vpc_id, published by vpc)"
}

data "aws_ssm_parameter" "al2023" { name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64" }

resource "aws_iam_instance_profile" "app" {
  name = "${var.env}-app"
  role = var.role_app_name
}

resource "aws_launch_template" "app" {
  name_prefix            = "${var.env}-app-"
  image_id               = data.aws_ssm_parameter.al2023.value # latest AMI, resolved at plan time
  instance_type          = "t4g.medium"                        # Graviton (arm64)
  update_default_version = true
  iam_instance_profile { name = aws_iam_instance_profile.app.name }
  vpc_security_group_ids = [var.sg_app_id]
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  } # IMDSv2 only
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }
  user_data = base64encode(templatefile("${path.module}/userdata.sh", { env = var.env }))
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.env}-app" }
  }
  lifecycle { create_before_destroy = true }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${var.env}-app"
  min_size                  = 2
  max_size                  = 6
  desired_capacity          = 2
  vpc_zone_identifier       = var.private_subnet_ids # spans AZs
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB" # use the LB's view of health, not just EC2's
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 90
      instance_warmup        = 120
    }
  }
  tag {
    key                 = "Name"
    value               = "${var.env}-app"
    propagate_at_launch = true
  }
  lifecycle { ignore_changes = [desired_capacity] } # autoscaling owns this number
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageCPUUtilization" }
    target_value = 60
  }
}
resource "aws_lb_target_group" "app" {
  name        = "${var.env}-ec2-app"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance" # EC2 targets (not pod IPs)
  health_check { path = "/health" }
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R33 — EC2 + launch template + Auto Scaling Group + target-group attachment + instance profile  [B]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# ── 1. What it is, in one breath ──
# A launch template says *what* an instance looks like (AMI, size, role, user-data). An
# Auto Scaling Group (ASG) keeps *N* of them running across AZs, replacing any that die and
# scaling with load. An instance profile is the wrapper that attaches an IAM role to an
# instance. This is how Jenkins agents, bastions and non-container workloads are built.
#
# ── 2. Where it sits ──
# L3. Depends on: VPC/subnets, SG, IAM role (R22), AMI. Consumed by: ALB/NLB target groups
# (R51/R52).
# Whirlpool: ❌ not in this repo (workloads ran on EKS).
#
# CFN type names: `AWS::EC2::LaunchTemplate`, `AWS::AutoScaling::AutoScalingGroup` (use
# `CreationPolicy` + `UpdatePolicy` for rolling updates), `AWS::IAM::InstanceProfile`.
#
# ── 6. Syntax decoded — Terraform ──
#
#   ▸ `data "aws_ssm_parameter"` for the AMI
#       what it does: Resolves the newest official AMI
#       why it matters: Avoids hard-coding an AMI ID that disappears
#   ▸ `iam_instance_profile`
#       what it does: Attaches the role to the instance
#       why it matters: An IAM role cannot attach to EC2 directly — it needs the profile
#   ▸ `metadata_options.http_tokens = "required"`
#       what it does: IMDSv2 only
#       why it matters: Blocks the SSRF-to-credentials attack path
#   ▸ `block_device_mappings … encrypted`
#       what it does: Encrypts the root volume
#       why it matters: Default is off in older accounts
#   ▸ `user_data` + `templatefile`
#       what it does: Boot script with variables
#       why it matters: Changing it → new launch-template version → instance refresh
#   ▸ `vpc_zone_identifier`
#       what it does: Subnets (⇒ AZs) the ASG may use
#       why it matters: Spans AZs for HA
#   ▸ `health_check_type = "ELB"`
#       what it does: Replace instances the load balancer says are bad
#       why it matters: `EC2` type only checks the VM is running, not that the app works
#   ▸ `health_check_grace_period`
#       what it does: Time before health checks begin
#       why it matters: Too short = instances killed while booting
#   ▸ `launch_template.version = "$Latest"`
#       what it does: Always use the newest version
#       why it matters: With `instance_refresh` it rolls the fleet on change
#   ▸ `instance_refresh`
#       what it does: Rolling replacement
#       why it matters: `min_healthy_percentage` = how much stays up
#   ▸ `ignore_changes = [desired_capacity]`
#       what it does: Don't undo scaling
#       why it matters: Otherwise every apply resets the scaled count
#   ▸ `TargetTrackingScaling`
#       what it does: "Keep average CPU at 60%"
#       why it matters: Simplest scaling policy that works
#
# ── 7. How it connects ──
# `ASG → registers instances → target group (R51/R52) ← listener ← LB`; role → S3/SSM/etc. If out of
# order: the target group must exist before the ASG references it.
#
# ── 8. Must-know box ──
# • Skeleton: instance profile · launch template (AMI, type, profile, SG, IMDSv2, volumes) · ASG
#   (min/max/desired, subnets, health check, target groups) · scaling policy.
# • Gotchas: forgetting `ignore_changes = [desired_capacity]`; `health_check_type = "ELB"`; IMDSv2;
#   an ASG across AZs needs capacity in each; launch templates are versioned — the ASG must point at
#   the right version.
# • CFN vs TF difference: CFN controls rolling updates with `UpdatePolicy`/`CreationPolicy` and
#   `cfn-signal`; Terraform uses `instance_refresh`.
# • Interview angle: `Iac.md` §Q-architecture.
