variable "name" {
  description = "Name prefix for the launch template and Auto Scaling Group."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name tag used to scope Spot eviction SSM targeting."
  type        = string
}

variable "availability_zone" {
  description = "Single AZ this ASG-of-1 is pinned to (must match the subnet)."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet ID in availability_zone."
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the launch template."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the node."
  type        = string
}

variable "data_volume_size_gb" {
  description = "Size of the durable data EBS volume in GiB."
  type        = number
}

variable "data_volume_type" {
  description = "EBS volume type for the durable data volume."
  type        = string
  default     = "gp3"
}

variable "data_volume_device_name" {
  description = "Device name used when attaching the data volume (e.g. /dev/xvdf)."
  type        = string
  default     = "/dev/xvdf"
}

variable "data_volume_mount_point" {
  description = "Filesystem mount point for the data volume."
  type        = string
  default     = "/data"
}

variable "user_data_template_path" {
  description = "Absolute path to the user-data shell template."
  type        = string
}

variable "init_application_b64" {
  description = "Base64-encoded init_application.sh installed under /opt/zero (runs once per data volume)."
  type        = string
}

variable "startup_application_b64" {
  description = "Base64-encoded startup_application.sh installed under /opt/zero."
  type        = string
}

variable "shutdown_application_b64" {
  description = "Base64-encoded shutdown_application.sh installed under /opt/zero."
  type        = string
}

variable "handle_spot_eviction_b64" {
  description = "Base64-encoded handle_spot_eviction.sh installed under /opt/zero."
  type        = string
}

variable "cache_bucket" {
  description = "S3 artifact cache bucket name (for node.env and IAM)."
  type        = string
}

variable "cache_bucket_arn" {
  description = "S3 artifact cache bucket ARN (for IAM)."
  type        = string
}

variable "elasticsearch_s3_key" {
  description = "Object key of the cached Elasticsearch tarball."
  type        = string
}

variable "elasticsearch_s3_uri" {
  description = "s3:// URI of the cached Elasticsearch tarball (written to node.env)."
  type        = string
}

variable "tags" {
  description = "Extra tags merged onto taggable resources."
  type        = map(string)
  default     = {}
}
