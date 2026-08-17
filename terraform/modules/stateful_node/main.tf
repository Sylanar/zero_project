# Single-AZ ASG of size 1: identity stays tied to one AZ so EBS can reattach
# after Spot replacement without crossing AZ boundaries.
#
# The data volume is a Terraform-managed resource (not LT block_device_mappings)
# so instance termination never deletes node state.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  instance_arn_prefix      = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
  handle_spot_eviction_b64 = base64encode(file("${path.module}/scripts/handle_spot_eviction.sh"))
  watch_spot_eviction_b64  = base64encode(file("${path.module}/scripts/watch_spot_eviction.sh"))
}

resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size_gb
  type              = var.data_volume_type
  encrypted         = true

  tags = merge(var.tags, {
    Name         = "${var.name}-data"
    StatefulNode = var.name
    Cluster      = var.cluster_name
  })
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
    ]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# AttachVolume is scoped to this node's volume ARN; Describe* cannot use
# resource-level ARNs on EC2, so those actions use the account EC2 volume wildcard.
data "aws_iam_policy_document" "node" {
  statement {
    sid    = "DescribeVolumes"
    effect = "Allow"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumeStatus",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AttachOwnVolume"
    effect = "Allow"
    actions = [
      "ec2:AttachVolume",
    ]
    resources = [
      aws_ebs_volume.data.arn,
      local.instance_arn_prefix,
    ]
  }

  statement {
    sid    = "TerminateSelf"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
    ]
    resources = [local.instance_arn_prefix]
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/StatefulNode"
      values   = [var.name]
    }
  }

  # Least privilege: cached Elasticsearch tarball and discovery-ec2 plugin zip.
  statement {
    sid    = "ReadCachedElasticsearch"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "${var.cache_bucket_arn}/${var.elasticsearch_s3_key}",
      "${var.cache_bucket_arn}/${var.discovery_ec2_s3_key}",
    ]
  }

  # Conditional Put/Get/Delete on the single eviction mutex object.
  statement {
    sid    = "EvictionLock"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${var.cache_bucket_arn}/${var.eviction_lock_s3_key}",
    ]
  }

  # One JSON object per eviction audit event (notice, lock, shutdown, join).
  statement {
    sid    = "EvictionLog"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "${var.cache_bucket_arn}/${var.eviction_log_s3_prefix}/*",
    ]
  }

  # discovery-ec2 lists peers by tag; DescribeInstances cannot be resource-scoped.
  statement {
    sid    = "DescribeInstancesForDiscovery"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.es_secrets_backend == "secretsmanager" ? [1] : []
    content {
      sid    = "ReadElasticsearchSecrets"
      effect = "Allow"
      actions = [
        "secretsmanager:GetSecretValue",
      ]
      resources = [
        var.es_bootstrap_secret_arn,
        var.es_tls_secret_arn,
      ]
    }
  }

  dynamic "statement" {
    for_each = var.es_secrets_backend == "s3" ? [1] : []
    content {
      sid    = "ReadElasticsearchSecretsFromS3"
      effect = "Allow"
      actions = [
        "s3:GetObject",
      ]
      resources = [
        "${var.cache_bucket_arn}/${var.es_bootstrap_s3_key}",
        "${var.cache_bucket_arn}/${var.es_tls_s3_key}",
      ]
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix        = "${var.name}-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = merge(var.tags, {
    Name    = var.name
    Cluster = var.cluster_name
  })
}

resource "aws_iam_role_policy" "node" {
  name_prefix = "node-"
  role        = aws_iam_role.this.id
  policy      = data.aws_iam_policy_document.node.json
}

# SSM agent + Run Command (Spot eviction via EventBridge). Prod only.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  count = var.enable_ssm_core ? 1 : 0

  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.this.name

  tags = merge(var.tags, {
    Name    = var.name
    Cluster = var.cluster_name
  })
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  vpc_security_group_ids = var.security_group_ids

  # Keep the AMI root small — AL2023 often defaults ~30 GiB; gp3 at 8 GiB is
  # usually the cheapest usable size when the snapshot allows it.
  block_device_mappings {
    device_name = var.root_volume_device_name

    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  # gzip so the decoded blob stays under EC2's 16 KiB user-data cap.
  user_data = base64gzip(templatefile("${path.module}/scripts/user_data.sh", {
    node_name                  = var.name
    device_name                = var.data_volume_device_name
    mount_point                = var.data_volume_mount_point
    volume_id                  = aws_ebs_volume.data.id
    init_application_b64       = var.init_application_b64
    startup_application_b64    = var.startup_application_b64
    shutdown_application_b64   = var.shutdown_application_b64
    handle_spot_eviction_b64   = local.handle_spot_eviction_b64
    watch_spot_eviction_b64    = local.watch_spot_eviction_b64
    log_eviction_event_b64     = var.log_eviction_event_b64
    enable_imds_eviction       = var.enable_imds_eviction ? "true" : "false"
    elasticsearch_s3_uri       = var.elasticsearch_s3_uri
    discovery_ec2_s3_uri       = var.discovery_ec2_s3_uri
    cache_bucket               = var.cache_bucket
    cluster_name               = var.cluster_name
    aws_region                 = var.aws_region
    es_initial_master_nodes    = var.es_initial_master_nodes
    es_discovery_azs           = var.es_discovery_azs
    es_secrets_backend         = var.es_secrets_backend
    es_bootstrap_secret_arn    = var.es_bootstrap_secret_arn
    es_tls_secret_arn          = var.es_tls_secret_arn
    es_bootstrap_s3_uri        = var.es_bootstrap_s3_uri
    es_tls_s3_uri              = var.es_tls_s3_uri
    es_node_name               = var.es_node_name
    es_node_roles              = var.es_node_roles
    es_expected_nodes          = var.es_expected_nodes
    eviction_lock_s3_key       = var.eviction_lock_s3_key
    eviction_lock_wait_seconds = var.eviction_lock_wait_seconds
    eviction_log_s3_prefix     = var.eviction_log_s3_prefix
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Spot capacity is chosen by the ASG mixed_instances_policy (not LT market options).

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name              = var.name
      AvailabilityZone  = var.availability_zone
      StatefulNode      = var.name
      Cluster           = var.cluster_name
      ElasticsearchRole = var.es_node_roles == "" ? "all" : var.es_node_roles
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name    = "${var.name}-root"
      Cluster = var.cluster_name
    })
  }

  tags = merge(var.tags, {
    Name    = var.name
    Cluster = var.cluster_name
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name                      = var.name
  vpc_zone_identifier       = [var.subnet_id]
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  health_check_type         = "EC2"
  health_check_grace_period = 300

  # On-Demand (e.g. dedicated masters): single type from the launch template.
  dynamic "launch_template" {
    for_each = var.spot_enabled ? [] : [1]
    content {
      id      = aws_launch_template.this.id
      version = aws_launch_template.this.latest_version
    }
  }

  # Spot data nodes: same-AZ type overrides + allocation strategy (retries can pick another type).
  dynamic "mixed_instances_policy" {
    for_each = var.spot_enabled ? [1] : []
    content {
      instances_distribution {
        on_demand_base_capacity                  = 0
        on_demand_percentage_above_base_capacity = 0
        spot_allocation_strategy                 = var.spot_allocation_strategy
      }

      launch_template {
        launch_template_specification {
          launch_template_id = aws_launch_template.this.id
          version            = aws_launch_template.this.latest_version
        }

        dynamic "override" {
          for_each = var.spot_instance_types
          content {
            instance_type = override.value
          }
        }
      }
    }
  }

  tag {
    key                 = "Name"
    value               = var.name
    propagate_at_launch = true
  }

  tag {
    key                 = "AvailabilityZone"
    value               = var.availability_zone
    propagate_at_launch = true
  }

  tag {
    key                 = "StatefulNode"
    value               = var.name
    propagate_at_launch = true
  }

  tag {
    key                 = "Cluster"
    value               = var.cluster_name
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}
