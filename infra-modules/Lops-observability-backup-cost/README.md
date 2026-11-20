# Lops-observability-backup-cost

Alarms, dashboards, backup, patching. Rides inside pipeline-platform; cost governance rides in pipeline-global.

- **Delivered by:** `pipelines/Jenkinsfile-platform`
- **Tool:** Terraform
- **Rule:** dependencies point *downward only*. Nothing in this layer may need something from a layer above it.

| Module folder | Resource | Tier |
|---|---|---|
| `observability-alarms/` | R64 | A |
| `amp-grafana/` | R65 | C |
| `xray-tracing/` | R66 | C |
| `ssm-fleet/` | R67 | C |
| `backup/` | R68 | B |
