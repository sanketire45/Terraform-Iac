# Evaluated against tfplan.json (resolved values), not HCL.
# Rule: every taggable resource that is created/updated must carry the mandatory tags in its RESOLVED tag set (`tags_all` = the resource's tags
#       merged with the provider's default_tags): Environment, Application, Owner, CostCenter, DataClassification, ManagedBy = terraform.
# Resources whose tags are not known yet at plan time (tags_all absent) are skipped — they are checked again by the Tag Policy / SCP in the account.
package main

import data.lib.plan
import rego.v1

mandatory := {"Environment", "Application", "Owner", "CostCenter", "DataClassification", "ManagedBy"}

deny contains msg if {
	some rc in input.resource_changes
	a := plan.after(rc)
	is_object(a.tags_all)
	missing := {t | some t in mandatory; not a.tags_all[t]}
	count(missing) > 0
	msg := sprintf("%s: missing mandatory tag(s) %v", [rc.address, sort(missing)])
}

deny contains msg if {
	some rc in input.resource_changes
	a := plan.after(rc)
	is_object(a.tags_all)
	a.tags_all.ManagedBy
	a.tags_all.ManagedBy != "terraform"
	msg := sprintf("%s: tag ManagedBy must be 'terraform' (found '%s')", [rc.address, a.tags_all.ManagedBy])
}
