# Single-AZ ASG of size 1: identity stays tied to one AZ so EBS can reattach
# after Spot replacement without crossing AZ boundaries.
#
# The data volume is a Terraform-managed resource (not LT block_device_mappings)
# so instance termination never deletes node state.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  instance_arn_prefix = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
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

  # Least privilege: only the cached Elasticsearch object for init_application.
  statement {
    sid    = "ReadCachedElasticsearch"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = ["${var.cache_bucket_arn}/${var.elasticsearch_s3_key}"]
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

# SSM agent + Run Command (Spot eviction via EventBridge).
resource "aws_iam_role_policy_attachment" "ssm_core" {
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

  user_data = base64encode(templatefile(var.user_data_template_path, {
    node_name                = var.name
    device_name              = var.data_volume_device_name
    mount_point              = var.data_volume_mount_point
    volume_id                = aws_ebs_volume.data.id
    init_application_b64     = var.init_application_b64
    startup_application_b64  = var.startup_application_b64
    shutdown_application_b64 = var.shutdown_application_b64
    handle_spot_eviction_b64 = var.handle_spot_eviction_b64
    elasticsearch_s3_uri     = var.elasticsearch_s3_uri
    cache_bucket             = var.cache_bucket
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  instance_market_options {
    market_type = "spot"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name             = var.name
      AvailabilityZone = var.availability_zone
      StatefulNode     = var.name
      Cluster          = var.cluster_name
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

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
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
