#!/bin/bash
# Rendered by templatefile(): ${env} comes from Terraform; a literal shell dollar must be written $${...}
set -euo pipefail
echo "APP_ENV=${env}" >> /etc/environment
dnf -y install amazon-cloudwatch-agent
systemctl enable --now amazon-ssm-agent
systemctl enable --now amazon-cloudwatch-agent
