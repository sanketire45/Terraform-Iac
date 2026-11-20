# ════════════════════════════════════════════════════════════════════════
#  MODULE : ecs-fargate
#  Layer  : L3-platform-data          Pipeline : pipeline-platform
#  Resource blueprint R34 [Tier C]  →  Iac_blueprint_masterclass.md, "R34"
#  Depends on : vpc, iam-roles
#  Consumed by: small-team containers
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

variable "ecr_url" {
  type        = string
  description = "Registry URL the task image is pulled from"
}

variable "image_tag" {
  type        = string
  description = "Container image tag to run (immutable tag, never \"latest\")"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet ids — read from the SSM contract (/<org>/<env>/network/private_subnet_ids, published by vpc)"
}

variable "role_ecs_exec_arn" {
  type        = string
  description = "Role ecs exec arn — read from the SSM contract (/<org>/<env>/iam/role_ecs_exec_arn, published by iam-roles)"
}

variable "role_ecs_task_arn" {
  type        = string
  description = "Role ecs task arn — read from the SSM contract (/<org>/<env>/iam/role_ecs_task_arn, published by iam-roles)"
}

variable "sg_api_id" {
  type        = string
  description = "Sg api id — read from the SSM contract (/<org>/<env>/network/sg_api_id, published by security-groups)"
}

variable "vpc_id" {
  type        = string
  description = "Vpc id — read from the SSM contract (/<org>/<env>/network/vpc_id, published by vpc)"
}

resource "aws_ecs_cluster" "this" {
  name = "${var.env}-apps"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
resource "aws_ecs_task_definition" "api" {
  family                   = "${var.env}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = var.role_ecs_exec_arn # pulls image, writes logs
  task_role_arn            = var.role_ecs_task_arn # what the app itself may do
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode([{
    name         = "api"
    image        = "${var.ecr_url}/api:${var.image_tag}"
    essential    = true
    portMappings = [{ containerPort = 8080 }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name,
        "awslogs-region"        = var.region,
        "awslogs-stream-prefix" = "api"
      }
    }
  }])
}
resource "aws_ecs_service" "api" {
  name            = "api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.sg_api_id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  lifecycle { ignore_changes = [desired_count] }
}
resource "aws_lb_target_group" "api" {
  name        = "${var.env}-ecs-api"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # awsvpc tasks get their own ENI/IP
  health_check { path = "/health" }
}

# helper log groups the excerpt referenced
resource "aws_cloudwatch_log_group" "api" {
  name              = "/${var.env}/api"
  retention_in_days = 30
  kms_key_id        = null # set to a CMK ARN where the log content is sensitive
}


# ═══════════════════════════════════════════════════════════════════════
# EXPLAINED — R34 — ECS cluster + task definition + service (Fargate)  [C]  🧪IDEAL
# (everything below is comments, copied from Iac_blueprint_masterclass.md)
# ═══════════════════════════════════════════════════════════════════════
#
# • Skeleton: cluster · task definition (cpu/memory, execution role and task role, container) ·
#   service (subnets, SG, target group, circuit breaker).
# • Gotchas: execution role ≠ task role (pull/log vs app permissions); Fargate `cpu`/`memory` must
#   be a valid pair; changing the task definition creates a new revision — the service must
#   reference it; `awsvpc` mode = one ENI per task (IP usage).
# • CFN type names: `AWS::ECS::Cluster`, `AWS::ECS::TaskDefinition`, `AWS::ECS::Service`.
