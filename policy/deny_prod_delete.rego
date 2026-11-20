# Evaluated against tfplan.json (resolved values), not HCL.
# Rule: deny any DELETE or REPLACE (delete+create) of a protected resource type when the resource is tagged Environment=prod,
#       unless its ADDRESS is in policy/data/exceptions.json → "prod_delete" (a reviewed, ticketed PR).
# Why tags_all: the resolved tag set includes the provider's default_tags, so the environment is known even if the module never sets it.
package main

import data.lib.plan
import rego.v1

protected := {
	"aws_db_instance",
	"aws_rds_cluster",
	"aws_rds_cluster_instance",
	"aws_rds_global_cluster",
	"aws_kms_key",
	"aws_s3_bucket",
	"aws_dynamodb_table",
	"aws_msk_cluster",
	"aws_efs_file_system",
	"aws_elasticache_replication_group",
	"aws_opensearch_domain",
	"aws_eks_cluster",
	"aws_backup_vault",
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type in protected
	"delete" in rc.change.actions
	rc.change.before.tags_all.Environment == "prod"
	not rc.address in plan.exceptions("prod_delete")
	verb := replace_or_delete(rc.change.actions)
	msg := sprintf("%s: plan would %s a protected %s in prod — add a prevent_destroy review, or a ticketed exception in policy/data/exceptions.json", [rc.address, verb, rc.type])
}

replace_or_delete(actions) := "REPLACE" if "create" in actions

replace_or_delete(actions) := "DELETE" if not "create" in actions
