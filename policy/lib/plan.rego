# Shared helpers for the policy files. Package `lib.plan` is NOT evaluated by conftest on its own (conftest runs package `main`);
# the rules import it:  import data.lib.plan
package lib.plan

import rego.v1

# True when the resource is being created or updated (replace = delete+create counts). Pure deletes / no-ops / reads do not.
changing(rc) if {
	some a in rc.change.actions
	a in {"create", "update"}
}

# The planned (resolved) attributes of a changing resource.
after(rc) := rc.change.after if {
	changing(rc)
	is_object(rc.change.after)
}

# Normalise "a list, or null/absent" to a list, so `some x in as_list(v)` never errors.
as_list(v) := v if is_array(v)

as_list(v) := [] if not is_array(v)

# One value or a list → always a list (IAM Action / Resource may be either).
one_or_many(v) := v if is_array(v)

one_or_many(v) := [v] if not is_array(v)

# Pre-approved exceptions from policy/data/exceptions.json (resource ADDRESSES, reviewed through CODEOWNERS).
exceptions(kind) := object.get(object.get(data, "exceptions", {}), kind, [])
