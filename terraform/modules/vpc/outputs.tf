output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Map of availability zone to private subnet ID."
  value       = { for az, subnet in aws_subnet.private : az => subnet.id }
}

output "private_subnet_cidr_blocks" {
  description = "Map of availability zone to private subnet CIDR."
  value       = { for az, subnet in aws_subnet.private : az => subnet.cidr_block }
}

output "private_route_table_ids" {
  description = "Map of availability zone to private route table ID."
  value       = { for az, rt in aws_route_table.private : az => rt.id }
}

output "interface_vpc_endpoint_ids" {
  description = "Map of interface VPC endpoint service short name to endpoint ID."
  value       = { for k, ep in aws_vpc_endpoint.interface : k => ep.id }
}

output "s3_vpc_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "public_subnet_id" {
  description = "Public subnet ID for the ingest gateway (null when enable_public_subnet is false)."
  value       = try(aws_subnet.public[0].id, null)
}

output "internet_gateway_id" {
  description = "Internet gateway ID (null when enable_public_subnet is false)."
  value       = try(aws_internet_gateway.this[0].id, null)
}
