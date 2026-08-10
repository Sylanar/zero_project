# One ASG-of-1 per node, round-robin across availability_zones so capacity
# spreads evenly while each node keeps a single-AZ identity for EBS affinity.

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  nodes = {
    for i in range(var.nodes_total) :
    format("node-%02d", i) => {
      index = i
      az    = var.availability_zones[i % length(var.availability_zones)]
    }
  }

  init_application_b64     = base64encode(file("${path.module}/scripts/init_application.sh"))
  startup_application_b64  = base64encode(file("${path.module}/scripts/startup_application.sh"))
  shutdown_application_b64 = base64encode(file("${path.module}/scripts/shutdown_application.sh"))
  handle_spot_eviction_b64 = base64encode(file("${path.module}/scripts/handle_spot_eviction.sh"))

  elasticsearch_s3_uri = "s3://${aws_s3_bucket.cache.id}/${local.elasticsearch_s3_key}"
}

module "stateful_node" {
  source   = "./modules/stateful_node"
  for_each = local.nodes

  name                     = "${var.cluster_name}-${each.key}"
  cluster_name             = var.cluster_name
  availability_zone        = each.value.az
  subnet_id                = module.vpc.private_subnet_ids[each.value.az]
  ami_id                   = data.aws_ssm_parameter.al2023_ami.value
  instance_type            = var.instance_type
  data_volume_size_gb      = var.data_volume_size_gb
  data_volume_type         = var.data_volume_type
  user_data_template_path  = "${path.module}/scripts/user_data.sh"
  init_application_b64     = local.init_application_b64
  startup_application_b64  = local.startup_application_b64
  shutdown_application_b64 = local.shutdown_application_b64
  handle_spot_eviction_b64 = local.handle_spot_eviction_b64
  cache_bucket             = aws_s3_bucket.cache.id
  cache_bucket_arn         = aws_s3_bucket.cache.arn
  elasticsearch_s3_key     = local.elasticsearch_s3_key
  elasticsearch_s3_uri     = local.elasticsearch_s3_uri

  # Ensure the tarball exists in the cache before first-boot init can run.
  depends_on = [terraform_data.seed_elasticsearch]
}
