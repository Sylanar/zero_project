# VPC and one private subnet per AZ for the stateful Spot cluster.
module "vpc" {
  source = "./modules/vpc"

  name               = var.cluster_name
  cidr_block         = var.vpc_cidr_block
  availability_zones = var.availability_zones
}
