# Dev ingest gateway: one On-Demand host in a public subnet, EIP as the stable
# Filebeat/Logstash target. TLS is passed through to a data node so the cluster
# CA still authenticates the session; 9300 stays closed.

data "aws_iam_policy_document" "ingest_gateway_assume" {
  count = local.ingest_gateway_enabled ? 1 : 0

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

# DescribeInstances cannot be resource-scoped on EC2; filter to this cluster in
# the proxy script via the Cluster tag.
data "aws_iam_policy_document" "ingest_gateway" {
  count = local.ingest_gateway_enabled ? 1 : 0

  statement {
    sid    = "DescribeInstancesForIngestProxy"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "ingest_gateway" {
  count = local.ingest_gateway_enabled ? 1 : 0

  name_prefix        = "${var.cluster_name}-ingest-"
  assume_role_policy = data.aws_iam_policy_document.ingest_gateway_assume[0].json

  tags = {
    Name    = "${var.cluster_name}-ingest-gateway"
    Cluster = var.cluster_name
  }
}

resource "aws_iam_role_policy" "ingest_gateway" {
  count = local.ingest_gateway_enabled ? 1 : 0

  name_prefix = "ingest-"
  role        = aws_iam_role.ingest_gateway[0].id
  policy      = data.aws_iam_policy_document.ingest_gateway[0].json
}

resource "aws_iam_instance_profile" "ingest_gateway" {
  count = local.ingest_gateway_enabled ? 1 : 0

  name_prefix = "${var.cluster_name}-ingest-"
  role        = aws_iam_role.ingest_gateway[0].name

  tags = {
    Name    = "${var.cluster_name}-ingest-gateway"
    Cluster = var.cluster_name
  }
}

resource "aws_security_group" "ingest_gateway" {
  count = local.ingest_gateway_enabled ? 1 : 0

  name_prefix = "${var.cluster_name}-ingest-"
  description = "Ingest gateway: 9200/22 from allowlisted clients, 9200 to ES"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name    = "${var.cluster_name}-ingest-gateway"
    Cluster = var.cluster_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ingest_gateway_http" {
  for_each = local.ingest_gateway_enabled ? toset(var.ingest_client_cidrs) : toset([])

  security_group_id = aws_security_group.ingest_gateway[0].id
  description       = "Elasticsearch HTTP from ingest client"
  from_port         = 9200
  to_port           = 9200
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "ingest_gateway_ssh" {
  for_each = local.ingest_gateway_enabled ? toset(var.ingest_client_cidrs) : toset([])

  security_group_id = aws_security_group.ingest_gateway[0].id
  description       = "SSH / EC2 Instance Connect from ingest client"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "ingest_gateway_es_http" {
  count = local.ingest_gateway_enabled ? 1 : 0

  security_group_id            = aws_security_group.ingest_gateway[0].id
  description                  = "Elasticsearch HTTP to cluster nodes"
  from_port                    = 9200
  to_port                      = 9200
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.elasticsearch.id
}

resource "aws_vpc_security_group_egress_rule" "ingest_gateway_https" {
  count = local.ingest_gateway_enabled ? 1 : 0

  security_group_id = aws_security_group.ingest_gateway[0].id
  description       = "HTTPS for dnf and AWS APIs"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "ingest_gateway_http_dnf" {
  count = local.ingest_gateway_enabled ? 1 : 0

  security_group_id = aws_security_group.ingest_gateway[0].id
  description       = "HTTP for dnf mirrors"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "ingest_gateway_dns_udp" {
  count = local.ingest_gateway_enabled ? 1 : 0

  security_group_id = aws_security_group.ingest_gateway[0].id
  description       = "DNS UDP"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "ingest_gateway_dns_tcp" {
  count = local.ingest_gateway_enabled ? 1 : 0

  security_group_id = aws_security_group.ingest_gateway[0].id
  description       = "DNS TCP"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "elasticsearch_http_ingest_gateway" {
  count = local.ingest_gateway_enabled ? 1 : 0

  security_group_id            = aws_security_group.elasticsearch.id
  description                  = "Elasticsearch HTTP from ingest gateway"
  from_port                    = 9200
  to_port                      = 9200
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.ingest_gateway[0].id
}

resource "aws_launch_template" "ingest_gateway" {
  count = local.ingest_gateway_enabled ? 1 : 0

  name_prefix   = "${var.cluster_name}-ingest-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.ingest_gateway_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ingest_gateway[0].name
  }

  network_interfaces {
    device_index                = 0
    subnet_id                   = module.vpc.public_subnet_id
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ingest_gateway[0].id]
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  user_data = base64gzip(templatefile("${path.module}/../scripts/ingest_gateway/user_data.sh", {
    ingest_proxy_b64 = base64encode(file("${path.module}/../scripts/ingest_gateway/ingest_proxy.py"))
    cluster_name     = var.cluster_name
    aws_region       = var.aws_region
    preferred_az     = var.availability_zones[0]
  }))

  update_default_version = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.cluster_name}-ingest-gateway"
      Cluster = var.cluster_name
      Role    = "ingest-gateway"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name    = "${var.cluster_name}-ingest-gateway-root"
      Cluster = var.cluster_name
    }
  }

  tags = {
    Name    = "${var.cluster_name}-ingest-gateway"
    Cluster = var.cluster_name
  }
}

resource "aws_instance" "ingest_gateway" {
  count = local.ingest_gateway_enabled ? 1 : 0

  launch_template {
    id      = aws_launch_template.ingest_gateway[0].id
    version = aws_launch_template.ingest_gateway[0].latest_version
  }

  tags = {
    Name    = "${var.cluster_name}-ingest-gateway"
    Cluster = var.cluster_name
    Role    = "ingest-gateway"
  }

  lifecycle {
    replace_triggered_by = [aws_launch_template.ingest_gateway[0].latest_version]
  }

  depends_on = [aws_iam_role_policy.ingest_gateway]
}

resource "aws_eip" "ingest_gateway" {
  count = local.ingest_gateway_enabled ? 1 : 0

  domain = "vpc"

  tags = {
    Name    = "${var.cluster_name}-ingest-gateway"
    Cluster = var.cluster_name
  }

  depends_on = [module.vpc]
}

resource "aws_eip_association" "ingest_gateway" {
  count = local.ingest_gateway_enabled ? 1 : 0

  instance_id   = aws_instance.ingest_gateway[0].id
  allocation_id = aws_eip.ingest_gateway[0].id
}
