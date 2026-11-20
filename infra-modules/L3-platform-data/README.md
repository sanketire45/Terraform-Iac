# L3-platform-data

KMS, secrets, IAM, S3, ECR, databases, messaging, EKS control plane + nodes. Monthly. High blast radius.

- **Delivered by:** `pipelines/Jenkinsfile-platform`
- **Tool:** Terraform
- **Rule:** dependencies point *downward only*. Nothing in this layer may need something from a layer above it.

| Module folder | Resource | Tier |
|---|---|---|
| `kms/` | R18 | A |
| `secrets/` | R19 | A |
| `ssm-contract/` | R20 | B |
| `s3/` | R21 | A |
| `iam-roles/` | R22 | A |
| `private-ca/` | R23 | B |
| `rds-aurora/` | R24 | A |
| `aurora-global/` | R25 | B |
| `dynamodb/` | R26 | A |
| `elasticache/` | R27 | B |
| `opensearch/` | R28 | B |
| `analytics/` | R29 | C |
| `msk/` | R30 | A |
| `efs/` | R31 | B |
| `ecr/` | R32 | A |
| `ec2-asg/` | R33 | B |
| `ecs-fargate/` | R34 | C |
| `messaging-sqs-sns/` | R35 | B |
| `eventbridge/` | R36 | B |
| `kinesis-firehose/` | R37 | B |
| `iot-core/` | R38 | B |
| `eks-cluster/` | R39 | A |
| `eks-irsa/` | R40 | A |
| `eks-pod-identity/` | R41 | B |
| `eks-access/` | R42 | B |
| `eks-nodes/` | R43 | A |
| `eks-fargate/` | R44 | C |
| `eks-managed-addons/` | R45 | B |
