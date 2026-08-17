locals {
  az_map = {
    for idx, az in var.availability_zones :
    az => {
      index      = idx
      cidr_block = cidrsubnet(var.cidr_block, var.private_subnet_newbits, idx)
    }
  }

  # Empty interface_endpoint_subnet_azs → every private subnet (prod).
  interface_endpoint_subnet_ids = length(var.interface_endpoint_subnet_azs) > 0 ? [
    for az in var.interface_endpoint_subnet_azs : aws_subnet.private[az].id
  ] : [for s in aws_subnet.private : s.id]
}

data "aws_region" "current" {}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = var.name
  })
}

resource "aws_subnet" "private" {
  for_each = local.az_map

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.cidr_block
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-private-${each.key}"
    Tier = "private"
  })
}

resource "aws_route_table" "private" {
  for_each = local.az_map

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-private-${each.key}"
    Tier = "private"
  })
}

resource "aws_route_table_association" "private" {
  for_each = local.az_map

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# Interface endpoints so private instances can call selected AWS APIs with no NAT.
resource "aws_security_group" "vpc_endpoints" {
  count = length(var.interface_endpoint_services) > 0 ? 1 : 0

  name_prefix = "${var.name}-vpce-"
  description = "HTTPS from VPC to interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  egress {
    description = "Allow endpoint responses"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  tags = merge(var.tags, {
    Name = "${var.name}-vpce"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoint_services

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = local.interface_endpoint_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.tags, {
    Name = "${var.name}-${each.value}"
  })
}

# One public subnet + IGW for the ingest gateway only. Cluster nodes stay private.
resource "aws_internet_gateway" "this" {
  count = var.enable_public_subnet ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-igw"
  })
}

resource "aws_subnet" "public" {
  count = var.enable_public_subnet ? 1 : 0

  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.public_subnet_az
  cidr_block              = cidrsubnet(var.cidr_block, var.private_subnet_newbits, 200)
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name}-public-${var.public_subnet_az}"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  count = var.enable_public_subnet ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-public"
    Tier = "public"
  })
}

resource "aws_route" "public_internet" {
  count = var.enable_public_subnet ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count = var.enable_public_subnet ? 1 : 0

  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

# Gateway endpoint: private nodes pull the ES artifact from the cache bucket
# without NAT or a public route.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]

  tags = merge(var.tags, {
    Name = "${var.name}-s3"
  })
}
