# Spot Cluster Infrastructure Project

## Tech Stack
- Terraform (AWS Provider v5.x)
- Bash (Linux / EC2 User Data)

## Architecture Principles
- Single-AZ Auto Scaling Groups of size 1 (Desired=1, Min=1, Max=1).
- EventBridge + SSM Run Command for graceful node eviction handling.
- Dynamic EBS volume reattachment via AWS CLI tags at instance boot.

## Development Workflow
- Keep code DRY (Don't Repeat Yourself) but hyper-focused.
- Run `terraform validate` and `terraform fmt` to verify your syntax suggestions.
