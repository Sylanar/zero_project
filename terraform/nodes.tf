# One ASG-of-1 per node, round-robin across availability_zones so capacity
# spreads evenly while each node keeps a single-AZ identity for EBS affinity.
# dedicated_masters=true adds one On-Demand master per AZ; nodes_total are data-only.

# Graviton AMI — must match elasticsearch_arch (linux-aarch64) and an arm64 instance type.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  data_nodes = {
    for i in range(var.nodes_total) :
    format("node-%02d", i) => {
      az                  = var.availability_zones[i % length(var.availability_zones)]
      instance_type       = var.instance_type
      data_volume_size_gb = var.data_volume_size_gb
      spot_enabled        = true
      es_node_roles       = var.dedicated_masters ? "data,ingest" : ""
    }
  }

  master_nodes = var.dedicated_masters ? {
    for i, az in var.availability_zones :
    format("master-%02d", i) => {
      az                  = az
      instance_type       = var.master_instance_type
      data_volume_size_gb = var.master_data_volume_size_gb
      spot_enabled        = false
      es_node_roles       = "master"
    }
  } : {}

  nodes = merge(local.data_nodes, local.master_nodes)

  es_bootstrap_nodes = var.dedicated_masters ? sort(keys(local.master_nodes)) : var.es_initial_master_nodes

  init_application_b64     = base64encode(file("${path.module}/../scripts/application/init_application.sh"))
  startup_application_b64  = base64encode(file("${path.module}/../scripts/application/startup_application.sh"))
  shutdown_application_b64 = base64encode(file("${path.module}/../scripts/application/shutdown_application.sh"))
  log_eviction_event_b64   = base64encode(file("${path.module}/../scripts/application/log_eviction_event.sh"))

  elasticsearch_s3_uri = "s3://${aws_s3_bucket.cache.id}/${local.elasticsearch_s3_key}"
  discovery_ec2_s3_uri = "s3://${aws_s3_bucket.cache.id}/${local.discovery_ec2_s3_key}"

  es_expected_nodes = length(local.nodes)

  # Spot overrides: explicit list, or fall back to the single instance_type.
  spot_instance_types = length(var.spot_instance_types) > 0 ? var.spot_instance_types : [var.instance_type]
}

check "es_initial_master_nodes_exist" {
  assert {
    condition = var.dedicated_masters || alltrue([
      for n in var.es_initial_master_nodes : contains(keys(local.data_nodes), n)
    ])
    error_message = "Each es_initial_master_nodes entry must be a data node key created by nodes_total (e.g. node-00)."
  }
}

check "dedicated_masters_az_count" {
  assert {
    condition     = !var.dedicated_masters || length(var.availability_zones) >= 3
    error_message = "dedicated_masters requires at least three availability_zones (one master each)."
  }
}

module "stateful_node" {
  source   = "./modules/stateful_node"
  for_each = local.nodes

  name                       = "${var.cluster_name}-${each.key}"
  cluster_name               = var.cluster_name
  availability_zone          = each.value.az
  subnet_id                  = module.vpc.private_subnet_ids[each.value.az]
  ami_id                     = data.aws_ssm_parameter.al2023_ami.value
  instance_type              = each.value.instance_type
  spot_instance_types        = each.value.spot_enabled ? local.spot_instance_types : [each.value.instance_type]
  spot_allocation_strategy   = var.spot_allocation_strategy
  data_volume_size_gb        = each.value.data_volume_size_gb
  data_volume_type           = var.data_volume_type
  root_volume_size_gb        = var.root_volume_size_gb
  spot_enabled               = each.value.spot_enabled
  es_node_name               = each.key
  es_node_roles              = each.value.es_node_roles
  init_application_b64       = local.init_application_b64
  startup_application_b64    = local.startup_application_b64
  shutdown_application_b64   = local.shutdown_application_b64
  log_eviction_event_b64     = local.log_eviction_event_b64
  cache_bucket               = aws_s3_bucket.cache.id
  cache_bucket_arn           = aws_s3_bucket.cache.arn
  elasticsearch_s3_key       = local.elasticsearch_s3_key
  elasticsearch_s3_uri       = local.elasticsearch_s3_uri
  discovery_ec2_s3_key       = local.discovery_ec2_s3_key
  discovery_ec2_s3_uri       = local.discovery_ec2_s3_uri
  security_group_ids         = [aws_security_group.elasticsearch.id]
  aws_region                 = var.aws_region
  es_initial_master_nodes    = join(",", local.es_bootstrap_nodes)
  es_discovery_azs           = join(",", var.availability_zones)
  es_secrets_backend         = local.es_secrets_backend
  es_bootstrap_secret_arn    = try(aws_secretsmanager_secret.elasticsearch_bootstrap[0].arn, "")
  es_tls_secret_arn          = try(aws_secretsmanager_secret.elasticsearch_tls[0].arn, "")
  es_bootstrap_s3_key        = local.es_bootstrap_s3_key
  es_tls_s3_key              = local.es_tls_s3_key
  es_bootstrap_s3_uri        = local.is_dev ? local.es_bootstrap_s3_uri : ""
  es_tls_s3_uri              = local.is_dev ? local.es_tls_s3_uri : ""
  enable_ssm_core            = local.is_prod
  enable_imds_eviction       = local.is_dev
  es_expected_nodes          = local.es_expected_nodes
  eviction_lock_s3_key       = local.eviction_lock_s3_key
  eviction_lock_wait_seconds = var.eviction_lock_wait_seconds
  eviction_log_s3_prefix     = local.eviction_log_s3_prefix

  depends_on = [
    terraform_data.seed_elasticsearch,
    terraform_data.seed_discovery_ec2,
    module.vpc,
    aws_secretsmanager_secret_version.elasticsearch_bootstrap,
    aws_secretsmanager_secret_version.elasticsearch_tls,
    aws_s3_object.elasticsearch_bootstrap,
    aws_s3_object.elasticsearch_tls,
  ]
}
