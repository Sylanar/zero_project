# Artifact cache: seed once at apply so Spot replacements pull from S3
# instead of artifacts.elastic.co on every launch.

locals {
  elasticsearch_filename = "elasticsearch-${var.elasticsearch_version}-${var.elasticsearch_arch}.tar.gz"
  elasticsearch_url      = "https://artifacts.elastic.co/downloads/elasticsearch/${local.elasticsearch_filename}"
  elasticsearch_s3_key   = "elasticsearch/${local.elasticsearch_filename}"
}

resource "aws_s3_bucket" "cache" {
  bucket = "${var.cluster_name}-cache-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.cluster_name}-cache"
  }
}

resource "aws_s3_bucket_public_access_block" "cache" {
  bucket = aws_s3_bucket.cache.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cache" {
  bucket = aws_s3_bucket.cache.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Download from Elastic and upload to S3 when version/arch/key changes.
# Runs on the machine executing terraform apply (needs curl + aws CLI).
resource "terraform_data" "seed_elasticsearch" {
  input = {
    url    = local.elasticsearch_url
    bucket = aws_s3_bucket.cache.id
    key    = local.elasticsearch_s3_key
  }

  provisioner "local-exec" {
    environment = {
      AWS_PROFILE        = var.aws_profile
      AWS_DEFAULT_REGION = var.aws_region
      SRC_URL            = local.elasticsearch_url
      DEST_URI           = "s3://${aws_s3_bucket.cache.id}/${local.elasticsearch_s3_key}"
    }

    command = <<-EOT
      set -euo pipefail
      TMP="$(mktemp)"
      trap 'rm -f "$TMP"' EXIT
      echo "Downloading $SRC_URL"
      curl -fsSL -o "$TMP" "$SRC_URL"
      echo "Uploading to $DEST_URI"
      aws s3 cp "$TMP" "$DEST_URI"
    EOT
  }

  depends_on = [
    aws_s3_bucket_public_access_block.cache,
    aws_s3_bucket_server_side_encryption_configuration.cache,
  ]
}
