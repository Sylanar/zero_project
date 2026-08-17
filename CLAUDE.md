# Spot Cluster Infrastructure Project

## Tech Stack
- Terraform (AWS Provider v5.x) — root module in `terraform/`
- Bash (Linux / EC2 User Data)

## Architecture Principles
- Single-AZ Auto Scaling Groups of size 1 (Desired=1, Min=1, Max=1).
- EventBridge + SSM Run Command for graceful node eviction handling (prod).
- Dynamic EBS volume reattachment via AWS CLI tags at instance boot.

## Development Workflow
- Keep code DRY but hyper-focused.
- Run Terraform from `terraform/`: `terraform fmt` and `terraform validate`.
