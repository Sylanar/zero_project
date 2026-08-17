# VPC and one private subnet per AZ for the stateful Spot cluster.
module "vpc" {
  source = "./modules/vpc"

  name                        = var.cluster_name
  cidr_block                  = var.vpc_cidr_block
  availability_zones          = var.availability_zones
  interface_endpoint_services = local.interface_endpoint_services
  # Empty = all private subnets; otherwise only listed AZs (dev: first AZ only).
  interface_endpoint_subnet_azs = local.is_prod ? [] : [var.availability_zones[0]]
  enable_public_subnet          = local.ingest_gateway_enabled
  public_subnet_az              = var.availability_zones[0]
  tags                          = var.default_tags
}
