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
  description = "SSM document invoked on Spot interruption warnings (prod only)."
  value       = try(aws_ssm_document.spot_eviction[0].name, null)
}

output "spot_interruption_rule_name" {
  description = "EventBridge rule name for Spot interruption warnings (prod only)."
  value       = try(aws_cloudwatch_event_rule.spot_interruption[0].name, null)
}

output "spot_eviction_dlq_url" {
  description = "SQS DLQ URL for failed EventBridge → SSM eviction invokes (prod only)."
  value       = try(aws_sqs_queue.spot_eviction_dlq[0].url, null)
}

output "spot_eviction_dlq_name" {
  description = "SQS DLQ name for failed Spot eviction EventBridge invokes (prod only)."
  value       = try(aws_sqs_queue.spot_eviction_dlq[0].name, null)
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

output "elasticsearch_security_group_id" {
  description = "Security group ID attached to Elasticsearch nodes (HTTP 9200, transport 9300)."
  value       = aws_security_group.elasticsearch.id
}

output "elasticsearch_bootstrap_password" {
  description = "Elasticsearch elastic user bootstrap password. Prefer an ingest user for Filebeat/Logstash."
  value       = random_password.elasticsearch_bootstrap.result
  sensitive   = true
}

output "elasticsearch_bootstrap_secret_arn" {
  description = "Secrets Manager ARN of the Elasticsearch elastic user bootstrap password (prod only)."
  value       = try(aws_secretsmanager_secret.elasticsearch_bootstrap[0].arn, null)
}

output "elasticsearch_tls_secret_arn" {
  description = "Secrets Manager ARN of the Elasticsearch CA and per-node TLS material (prod only)."
  value       = try(aws_secretsmanager_secret.elasticsearch_tls[0].arn, null)
}

output "elasticsearch_ca_s3_uri" {
  description = "s3:// URI of the Elasticsearch CA certificate for ingest clients."
  value       = local.es_ca_s3_uri
}

output "elasticsearch_ca_cert" {
  description = "PEM of the Elasticsearch HTTP CA. Trust this file; do not use tls.json."
  value       = tls_self_signed_cert.es_ca.cert_pem
  sensitive   = true
}

output "ingest_gateway_public_ip" {
  description = "Elastic IP of the dev ingest gateway (null when ingest_client_cidrs is empty)."
  value       = try(aws_eip.ingest_gateway[0].public_ip, null)
}

output "environment" {
  description = "Deployment mode: prod (full private APIs + SSM eviction) or dev (minimal)."
  value       = var.environment
}

output "dedicated_masters" {
  description = "Whether dedicated On-Demand master nodes were requested."
  value       = var.dedicated_masters
}