# policy/ — the policy gate (stage 9 of every pipeline)

Conftest / OPA rules evaluated against **`tfplan.json`** — the *resolved* plan — never against the HCL. A `deny` fails the build; a `warn` is printed.
Run by `pipelines/ci/policy_gate.sh`:  `conftest test <tfplan.json> --policy policy --data policy/data`

| File | Fails the plan when… |
|---|---|
| `deny_open_ssh.rego` | a security-group rule opens 22 / 3389 to `0.0.0.0/0` or `::/0` (inline `ingress`, `aws_security_group_rule`, `aws_vpc_security_group_ingress_rule`) |
| `deny_prod_delete.rego` | a protected type (RDS/Aurora, KMS, S3, DynamoDB, MSK, EFS, ElastiCache, OpenSearch, EKS, Backup vault) tagged `Environment=prod` would be **deleted or replaced** |
| `deny_public_s3.rego` | public ACL · weakened public-access-block · bucket policy with `Principal: *` and no Condition · a new bucket with no public-access-block |
| `deny_unencrypted.rego` | RDS/Aurora/EBS/EFS storage not encrypted · ElastiCache without at-rest + in-transit · MSK client_broker ≠ TLS · Kinesis not KMS · OpenSearch at-rest off |
| `deny_wildcard_iam.rego` | an IAM policy allows `Action:*` on `Resource:*` · (**warn**) a role has no permissions boundary |
| `require_tags.rego` | a taggable resource's resolved `tags_all` lacks Environment / Application / Owner / CostCenter / DataClassification / ManagedBy=terraform |
| `lib/plan.rego` | *(helpers: `changing`, `after`, `as_list`, `one_or_many`, `exceptions`)* |
| `data/exceptions.json` | the reviewed exception lists (resource **addresses**): `open_ssh`, `prod_delete`, `unencrypted` — changed only via a PR that CODEOWNERS approve |

Rego dialect: every file starts with `import rego.v1`, so it runs on OPA/Conftest versions that still default to the old syntax **and** on the ones that default to v1.

## Tests
`tests/run.sh` evaluates the fixtures in `tests/fixtures/`: `bad.plan.json` (a real `terraform show -json` of a deliberately bad config) **must** produce every
expected message, `good.plan.json` **must** pass clean, and `delete-prod.plan.json` exercises the prod-delete rule. Run it after changing any rule: `policy/tests/run.sh`.
