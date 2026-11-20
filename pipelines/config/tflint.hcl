# tflint configuration used by pipelines/ci/lint.sh
# `tflint --init` downloads the plugin below. Pin the version your agent image was built with.

config {
  call_module_type = "none"   # the leaves pull remote modules; those are linted separately as modules
}

plugin "aws" {
  enabled = true
  version = "0.38.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# a few rules that catch real mistakes in this repo's shape
rule "terraform_required_version" { enabled = true }
rule "terraform_required_providers" { enabled = true }
rule "terraform_unused_declarations" { enabled = true }
rule "terraform_deprecated_interpolation" { enabled = true }
rule "terraform_naming_convention" { enabled = true }
