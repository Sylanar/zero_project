# Spot Stateful Elasticsearch Lab

Cheap AWS lab for a **stateful Spot Elasticsearch cluster**: one Auto Scaling Group of size 1 per node identity, durable EBS reattached on replacement, optional allowlisted ingest gateway for Filebeat/Logstash.

## TL;DR

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit: aws_profile, aws_region, ingest_client_cidrs (your public IP /32)

terraform init
terraform apply

# wait ~2–5 min for nodes + gateway user-data, then:
../scripts/test_elasticsearch_connection.sh
```

Tear down when done:

```bash
cd terraform && terraform destroy
```

## Layout

| Path | Role |
|------|------|
| `terraform/` | Root module (apply from here) |
| `terraform/modules/vpc/` | VPC, private subnets, optional public subnet, endpoints |
| `terraform/modules/stateful_node/` | ASG-of-1 (EBS, IAM, launch template, boot/eviction) |
| `scripts/application/` | ES lifecycle on the node (init / startup / shutdown) |
| `scripts/ingest_gateway/` | Dev gateway proxy (socat + discovery) |
| `scripts/test_elasticsearch_connection.sh` | Smoke test + connection details |
| `scripts/spot_instance_types.sh` | Suggest Spot types for `tfvars` |
| `scripts/terminate_instances.sh` | Force-replace instances (EBS kept) |
| `scripts/on_node/` | Helpers meant to run *on* a node (e.g. via SSM) |

## Prerequisites

- Terraform `>= 1.5`
- AWS credentials (`aws_profile` in `terraform.tfvars` or `AWS_PROFILE`)
- Permissions for VPC, EC2, ASG, EBS, IAM, S3, and (prod) SSM / EventBridge / Secrets Manager
- Arm64/Graviton instance types matching `elasticsearch_arch = "linux-aarch64"`

## Configure

Copy and edit vars:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Minimum to care about for a first lab:

1. **`aws_profile` / `aws_region`** — where to create resources  
2. **`nodes_total` / `spot_instance_types`** — size and Spot mix  
3. **`ingest_client_cidrs`** — your public IP as `/32` if you want external HTTP access  

`environment = "dev"` is the cheap path (fewer VPC endpoints, secrets on S3, IMDS eviction).  
`environment = "prod"` adds Secrets Manager, multi-AZ endpoints, and EventBridge → SSM eviction.

## Apply

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

First apply downloads Elasticsearch + the discovery-ec2 plugin into an S3 cache (needs `curl` + AWS CLI on the machine running Terraform).

## Test the cluster (dev ingest gateway)

The gateway is created only when `environment = "dev"` **and** `ingest_client_cidrs` is non-empty. It exposes **TCP 9200** on a stable Elastic IP; TLS still terminates on the Elasticsearch node (cert CN is `node-00` / `node-03` / …, not the EIP).

```bash
# from repo root
./scripts/test_elasticsearch_connection.sh
./scripts/test_elasticsearch_connection.sh --print-secrets   # also prints elastic password
```

The script prints the gateway IP, CA path (`ca.crt` at repo root), and a ready-to-paste `curl` line, then hits `_cluster/health` and `_cat/nodes`.

### Filebeat / Logstash

```yaml
output.elasticsearch:
  hosts: ["https://<ingest_gateway_public_ip>:9200"]
  username: elastic          # prefer a dedicated ingest user in real use
  password: "..."
  ssl.certificate_authorities: ["ca.crt"]
  ssl.verification_mode: certificate
```

Pull CA / password without the smoke test:

```bash
cd terraform
terraform output -raw ingest_gateway_public_ip
terraform output -raw elasticsearch_ca_cert > ../ca.crt
terraform output -raw elasticsearch_bootstrap_password
```

If the smoke test times out, your current public IP is probably not in `ingest_client_cidrs` (or the gateway is still installing `socat`).

## Useful operators

```bash
# Rank Spot types for tfvars
./scripts/spot_instance_types.sh --top 5 --vcpus 2 --memory-gib 8

# Bounce instances (volumes stay; ASGs relaunch)
./scripts/terminate_instances.sh
```

## Architecture notes

- **Identity over scaling:** each node is an ASG of Desired=Min=Max=1 in a single AZ so its EBS volume can reattach after Spot replacement.
- **TLS:** shared CA + per-node certs named after stable keys (`node-00`, …). Transport uses certificate verification so IP changes do not break the cluster.
- **Eviction:** prod uses EventBridge + SSM; dev polls IMDS on the box. An S3 lock serializes concurrent Spot drains.
- **Do not open 9300** to the internet; only HTTP 9200 via the allowlisted gateway (or private connectivity you add later).
