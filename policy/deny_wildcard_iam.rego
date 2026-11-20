# Evaluated against tfplan.json (resolved values), not HCL.
# deny : an IAM policy statement that ALLOWS Action "*" on Resource "*" (full admin) — in aws_iam_policy / *_policy attachments to a role, user or group.
# warn : an IAM role without a permissions boundary (staged rollout: becomes `deny` once every role carries one).
#        Exempt by name: terraform-exec and ci-bootstrap are the pipeline's own roles; their power is guarded by the trust policy + ExternalId instead.
package main

import data.lib.plan
import rego.v1

policy_types := {"aws_iam_policy", "aws_iam_role_policy", "aws_iam_user_policy", "aws_iam_group_policy"}

star(v) if "*" in plan.one_or_many(v)

deny contains msg if {
	some rc in input.resource_changes
	rc.type in policy_types
	a := plan.after(rc)
	is_string(a.policy)
	doc := json.unmarshal(a.policy)
	some st in plan.one_or_many(doc.Statement)
	st.Effect == "Allow"
	star(st.Action)
	star(st.Resource)
	msg := sprintf("%s: IAM policy allows Action * on Resource * — grant the specific actions needed", [rc.address])
}

pipeline_roles := {"terraform-exec", "ci-bootstrap"}

warn contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_iam_role"
	a := plan.after(rc)
	not a.name in pipeline_roles
	object.get(a, "permissions_boundary", null) in {null, ""}
	msg := sprintf("%s: IAM role has no permissions boundary", [rc.address])
}
