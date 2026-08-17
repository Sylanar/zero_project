# Environment-derived toggles: prod keeps full private API surface + SSM eviction;
# dev strips cost (single-AZ ec2 endpoint, secrets on S3, IMDS self-eviction).

locals {
  is_prod = var.environment == "prod"
  is_dev  = var.environment == "dev"

  # Interface VPC endpoints: prod = full set in every AZ; dev = ec2 only in AZ[0].
  interface_endpoint_services = local.is_prod ? toset([
    "ec2",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "secretsmanager",
  ]) : toset(["ec2"])

  es_secrets_backend = local.is_prod ? "secretsmanager" : "s3"

  es_bootstrap_s3_key = "secrets/elasticsearch/bootstrap-password"
  es_tls_s3_key       = "secrets/elasticsearch/tls.json"

  es_bootstrap_s3_uri = "s3://${aws_s3_bucket.cache.id}/${local.es_bootstrap_s3_key}"
  es_tls_s3_uri       = "s3://${aws_s3_bucket.cache.id}/${local.es_tls_s3_key}"
  es_ca_s3_key        = "certs/ca.crt"
  es_ca_s3_uri        = "s3://${aws_s3_bucket.cache.id}/${local.es_ca_s3_key}"

  # Dev only: stable TCP 9200 proxy for Filebeat/Logstash when client CIDRs are set.
  ingest_gateway_enabled = local.is_dev && length(var.ingest_client_cidrs) > 0
}
