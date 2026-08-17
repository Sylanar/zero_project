# Elasticsearch cluster security: shared CA + per-node certs, bootstrap
# password, and a self-referencing SG. Certs are issued to stable node
# names (not Spot IPs) so verification_mode: certificate survives replacement.

resource "tls_private_key" "es_ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "es_ca" {
  private_key_pem       = tls_private_key.es_ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600
  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]

  subject {
    common_name = "${var.cluster_name} Elasticsearch CA"
  }
}

resource "tls_private_key" "es_node" {
  for_each = local.nodes

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "es_node" {
  for_each = local.nodes

  private_key_pem = tls_private_key.es_node[each.key].private_key_pem

  subject {
    common_name = each.key
  }

  dns_names = [each.key]
}

resource "tls_locally_signed_cert" "es_node" {
  for_each = local.nodes

  cert_request_pem      = tls_cert_request.es_node[each.key].cert_request_pem
  ca_private_key_pem    = tls_private_key.es_ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.es_ca.cert_pem
  validity_period_hours = 87600
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
  ]
}

resource "random_password" "elasticsearch_bootstrap" {
  length  = 32
  special = false
}

# Prod: Secrets Manager (private endpoint). Dev: same material on the cache
# bucket so nodes need only the free S3 gateway + ec2 interface endpoint.
resource "aws_secretsmanager_secret" "elasticsearch_bootstrap" {
  count = local.is_prod ? 1 : 0

  name                    = "${var.cluster_name}/elasticsearch/bootstrap-password"
  description             = "Elasticsearch elastic user bootstrap password"
  recovery_window_in_days = 0

  tags = {
    Name    = "${var.cluster_name}-es-bootstrap"
    Cluster = var.cluster_name
  }
}

resource "aws_secretsmanager_secret_version" "elasticsearch_bootstrap" {
  count = local.is_prod ? 1 : 0

  secret_id     = aws_secretsmanager_secret.elasticsearch_bootstrap[0].id
  secret_string = random_password.elasticsearch_bootstrap.result
}

resource "aws_secretsmanager_secret" "elasticsearch_tls" {
  count = local.is_prod ? 1 : 0

  name                    = "${var.cluster_name}/elasticsearch/tls"
  description             = "Elasticsearch CA and per-node TLS material"
  recovery_window_in_days = 0

  tags = {
    Name    = "${var.cluster_name}-es-tls"
    Cluster = var.cluster_name
  }
}

resource "aws_secretsmanager_secret_version" "elasticsearch_tls" {
  count = local.is_prod ? 1 : 0

  secret_id = aws_secretsmanager_secret.elasticsearch_tls[0].id
  secret_string = jsonencode({
    ca_cert = tls_self_signed_cert.es_ca.cert_pem
    nodes = {
      for k, cert in tls_locally_signed_cert.es_node :
      k => {
        cert = cert.cert_pem
        key  = tls_private_key.es_node[k].private_key_pem
      }
    }
  })
}

resource "aws_s3_object" "elasticsearch_bootstrap" {
  count = local.is_dev ? 1 : 0

  bucket       = aws_s3_bucket.cache.id
  key          = local.es_bootstrap_s3_key
  content      = random_password.elasticsearch_bootstrap.result
  content_type = "text/plain"
}

resource "aws_s3_object" "elasticsearch_tls" {
  count = local.is_dev ? 1 : 0

  bucket = aws_s3_bucket.cache.id
  key    = local.es_tls_s3_key
  content = jsonencode({
    ca_cert = tls_self_signed_cert.es_ca.cert_pem
    nodes = {
      for k, cert in tls_locally_signed_cert.es_node :
      k => {
        cert = cert.cert_pem
        key  = tls_private_key.es_node[k].private_key_pem
      }
    }
  })
  content_type = "application/json"
}

# CA only — clients (Filebeat/Logstash/curl) must not receive tls.json node keys.
resource "aws_s3_object" "elasticsearch_ca" {
  bucket       = aws_s3_bucket.cache.id
  key          = local.es_ca_s3_key
  content      = tls_self_signed_cert.es_ca.cert_pem
  content_type = "application/x-pem-file"
}

# Gateway-endpoint S3 traffic uses the S3 prefix list, not the VPC CIDR,
# so node egress must allow 443 there as well as to interface endpoints.
data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${data.aws_region.current.name}.s3"
}

resource "aws_security_group" "elasticsearch" {
  name_prefix = "${var.cluster_name}-es-"
  description = "Elasticsearch HTTP/transport among cluster nodes"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name    = "${var.cluster_name}-elasticsearch"
    Cluster = var.cluster_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "elasticsearch_http" {
  security_group_id            = aws_security_group.elasticsearch.id
  description                  = "Elasticsearch HTTP"
  from_port                    = 9200
  to_port                      = 9200
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.elasticsearch.id
}

resource "aws_vpc_security_group_ingress_rule" "elasticsearch_transport" {
  security_group_id            = aws_security_group.elasticsearch.id
  description                  = "Elasticsearch transport"
  from_port                    = 9300
  to_port                      = 9300
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.elasticsearch.id
}

resource "aws_vpc_security_group_egress_rule" "elasticsearch_http" {
  security_group_id            = aws_security_group.elasticsearch.id
  description                  = "Elasticsearch HTTP"
  from_port                    = 9200
  to_port                      = 9200
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.elasticsearch.id
}

resource "aws_vpc_security_group_egress_rule" "elasticsearch_transport" {
  security_group_id            = aws_security_group.elasticsearch.id
  description                  = "Elasticsearch transport"
  from_port                    = 9300
  to_port                      = 9300
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.elasticsearch.id
}

resource "aws_vpc_security_group_egress_rule" "elasticsearch_https_vpc" {
  security_group_id = aws_security_group.elasticsearch.id
  description       = "HTTPS to VPC interface endpoints"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = module.vpc.vpc_cidr_block
}

resource "aws_vpc_security_group_egress_rule" "elasticsearch_https_s3" {
  security_group_id = aws_security_group.elasticsearch.id
  description       = "HTTPS to S3 via gateway endpoint"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.s3.id
}
