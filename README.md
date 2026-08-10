# Spot Stateful Cluster

Terraform (AWS provider ~> 5.0) for a stateful Spot cluster using single-AZ Auto Scaling Groups of size 1, with bash user data for EBS reattachment at boot.

## Layout

| Path | Role |
|------|------|
| `versions.tf` / `providers.tf` | Terraform and AWS provider; region from `var.aws_region` |
| `variables.tf` / `outputs.tf` | Root inputs and outputs |
| `network.tf` / `iam.tf` / `asg.tf` | Cluster composition |
| `modules/stateful_node/` | Reusable ASG-of-1 unit |
| `scripts/` | EC2 user data and shared bash helpers |

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init
terraform plan
```
