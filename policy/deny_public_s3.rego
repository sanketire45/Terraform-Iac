# Evaluated against tfplan.json (resolved values), not HCL.
# Rules: deny a public ACL · deny a public-access-block that is not fully ON · deny a bucket policy that grants Principal "*" without a Condition ·
#        deny a NEW bucket that has no aws_s3_bucket_public_access_block in the same plan.
package main

import data.lib.plan
import rego.v1

public_acls := {"public-read", "public-read-write", "authenticated-read"}

# 1. public ACL (aws_s3_bucket_acl or the legacy acl attribute)
deny contains msg if {
	some rc in input.resource_changes
	rc.type in {"aws_s3_bucket_acl", "aws_s3_bucket"}
	a := plan.after(rc)
	a.acl in public_acls
	msg := sprintf("%s: public S3 ACL '%s'", [rc.address, a.acl])
}

# 2. public access block present but weakened (an attribute known to be false)
deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_s3_bucket_public_access_block"
	a := plan.after(rc)
	some attr in ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"]
	a[attr] == false
	msg := sprintf("%s: public access block has %s = false", [rc.address, attr])
}

# 3. bucket policy granting everyone access (Allow + Principal "*" + no Condition)
deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_s3_bucket_policy"
	a := plan.after(rc)
	is_string(a.policy)
	doc := json.unmarshal(a.policy)
	some st in plan.one_or_many(doc.Statement)
	st.Effect == "Allow"
	everyone(st.Principal)
	not st.Condition
	msg := sprintf("%s: bucket policy allows Principal * without a Condition", [rc.address])
}

everyone(p) if p == "*"

everyone(p) if p.AWS == "*"

# 4. every bucket created in this plan must have a public-access-block that references it
configured_buckets contains name if {
	walk(input.configuration, [_, node])
	is_object(node)
	node.type == "aws_s3_bucket_public_access_block"
	some ref in node.expressions.bucket.references
	startswith(ref, "aws_s3_bucket.")
	name := split(ref, ".")[1]
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_s3_bucket"
	plan.changing(rc)
	"create" in rc.change.actions
	not rc.name in configured_buckets
	msg := sprintf("%s: new S3 bucket has no aws_s3_bucket_public_access_block", [rc.address])
}
