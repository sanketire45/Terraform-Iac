# Evaluated against tfplan.json (resolved values), not HCL.
# Rule: deny unencrypted RDS / Aurora / EBS / EFS / MSK (client traffic) / Kinesis / ElastiCache / OpenSearch resources.
# Pre-approved exceptions: policy/data/exceptions.json → "unencrypted" (resource addresses).
package main

import data.lib.plan
import rego.v1

# attribute that must be true
must_be_true := {
	"aws_db_instance": "storage_encrypted",
	"aws_rds_cluster": "storage_encrypted",
	"aws_ebs_volume": "encrypted",
	"aws_efs_file_system": "encrypted",
}

deny contains msg if {
	some rc in input.resource_changes
	attr := must_be_true[rc.type]
	a := plan.after(rc)
	a[attr] != true
	not rc.address in plan.exceptions("unencrypted")
	msg := sprintf("%s (%s): %s must be true", [rc.address, rc.type, attr])
}

# ElastiCache: at rest AND in transit
deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_elasticache_replication_group"
	a := plan.after(rc)
	some attr in ["at_rest_encryption_enabled", "transit_encryption_enabled"]
	a[attr] != true
	not rc.address in plan.exceptions("unencrypted")
	msg := sprintf("%s: %s must be true", [rc.address, attr])
}

# MSK: clients must use TLS
deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_msk_cluster"
	a := plan.after(rc)
	some info in plan.as_list(a.encryption_info)
	some tr in plan.as_list(info.encryption_in_transit)
	tr.client_broker != "TLS"
	not rc.address in plan.exceptions("unencrypted")
	msg := sprintf("%s: MSK client_broker is '%s' — must be TLS", [rc.address, tr.client_broker])
}

# Kinesis: server-side encryption with KMS
deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_kinesis_stream"
	a := plan.after(rc)
	a.encryption_type != "KMS"
	not rc.address in plan.exceptions("unencrypted")
	msg := sprintf("%s: Kinesis encryption_type must be KMS", [rc.address])
}

# OpenSearch: encryption at rest enabled
deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_opensearch_domain"
	a := plan.after(rc)
	some enc in plan.as_list(a.encrypt_at_rest)
	enc.enabled != true
	not rc.address in plan.exceptions("unencrypted")
	msg := sprintf("%s: OpenSearch encrypt_at_rest.enabled must be true", [rc.address])
}
