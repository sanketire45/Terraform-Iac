# Evaluated against tfplan.json (resolved values), not HCL.
# Rule: deny any security-group rule that opens SSH (22) or RDP (3389) to the whole internet (0.0.0.0/0 or ::/0),
#       unless the resource ADDRESS is listed in policy/data/exceptions.json → "open_ssh" (reviewed PR, with a reason in the PR).
# Covers the three ways Terraform expresses it: inline `ingress {}` in aws_security_group, aws_security_group_rule, aws_vpc_security_group_ingress_rule.
package main

import data.lib.plan
import rego.v1

admin_ports := {22, 3389}

world(cidr) if cidr == "0.0.0.0/0"

world(cidr) if cidr == "::/0"

# protocol "-1" = all protocols/ports → includes 22; otherwise the port must fall inside [from, to] on tcp
covers(proto, _, _, _) if proto == "-1"

covers(proto, from, to, port) if {
	proto in {"tcp", "6"}
	from <= port
	port <= to
}

# 1. inline ingress blocks of aws_security_group
deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_security_group"
	a := plan.after(rc)
	some ing in plan.as_list(a.ingress)
	some cidr in array.concat(plan.as_list(ing.cidr_blocks), plan.as_list(ing.ipv6_cidr_blocks))
	world(cidr)
	some port in admin_ports
	covers(ing.protocol, ing.from_port, ing.to_port, port)
	not rc.address in plan.exceptions("open_ssh")
	msg := sprintf("%s: security group opens port %d to %s — use SSM Session Manager, or add a reviewed exception", [rc.address, port, cidr])
}

# 2. standalone aws_security_group_rule
deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_security_group_rule"
	a := plan.after(rc)
	a.type == "ingress"
	some cidr in array.concat(plan.as_list(a.cidr_blocks), plan.as_list(a.ipv6_cidr_blocks))
	world(cidr)
	some port in admin_ports
	covers(a.protocol, a.from_port, a.to_port, port)
	not rc.address in plan.exceptions("open_ssh")
	msg := sprintf("%s: security group rule opens port %d to %s", [rc.address, port, cidr])
}

# 3. aws_vpc_security_group_ingress_rule (one CIDR per resource)
deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_vpc_security_group_ingress_rule"
	a := plan.after(rc)
	cidr := object.get(a, "cidr_ipv4", object.get(a, "cidr_ipv6", ""))
	world(cidr)
	some port in admin_ports
	covers(object.get(a, "ip_protocol", ""), object.get(a, "from_port", 0), object.get(a, "to_port", 0), port)
	not rc.address in plan.exceptions("open_ssh")
	msg := sprintf("%s: ingress rule opens port %d to %s", [rc.address, port, cidr])
}
