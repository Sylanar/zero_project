output "vpc_id" {
  description = "ID of the cluster VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Map of availability zone to private subnet ID."
  value       = module.vpc.private_subnet_ids
}

output "node_asg_names" {
  description = "Map of node key to Auto Scaling Group name."
  value       = { for k, m in module.stateful_node : k => m.asg_name }
}

output "node_availability_zones" {
  description = "Map of node key to pinned availability zone."
  value       = { for k, m in module.stateful_node : k => m.availability_zone }
}

output "node_data_volume_ids" {
  description = "Map of node key to durable data EBS volume ID."
  value       = { for k, m in module.stateful_node : k => m.data_volume_id }
}

output "spot_eviction_ssm_document_name" {
  description = "SSM document invoked on Spot interruption warnings."
  value       = aws_ssm_document.spot_eviction.name
}

output "spot_interruption_rule_name" {
  description = "EventBridge rule name for Spot interruption warnings."
  value       = aws_cloudwatch_event_rule.spot_interruption.name
}

output "cache_bucket_id" {
  description = "S3 bucket ID for cached cluster artifacts (e.g. Elasticsearch tarball)."
  value       = aws_s3_bucket.cache.id
}

output "cache_bucket_arn" {
  description = "S3 bucket ARN for cached cluster artifacts."
  value       = aws_s3_bucket.cache.arn
}

output "elasticsearch_s3_uri" {
  description = "s3:// URI of the cached Elasticsearch tarball for launch scripts."
  value       = local.elasticsearch_s3_uri
}

output "elasticsearch_s3_key" {
  description = "Object key of the cached Elasticsearch tarball."
  value       = local.elasticsearch_s3_key
}