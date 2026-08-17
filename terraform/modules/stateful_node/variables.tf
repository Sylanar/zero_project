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
  description = "EC2 instance type for On-Demand nodes, and launch template default for Spot nodes."
  type        = string
}

variable "spot_instance_types" {
  description = "Ordered Spot instance type overrides (same AZ). Used only when spot_enabled is true."
  type        = list(string)

  validation {
    condition     = length(var.spot_instance_types) >= 1
    error_message = "spot_instance_types must contain at least one instance type."
  }
}

variable "spot_allocation_strategy" {
  description = "Spot allocation strategy when spot_enabled is true."
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

variable "spot_enabled" {
  description = "If true, launch as Spot. Dedicated masters should be false (On-Demand)."
  type        = bool
  default     = true
}

variable "es_node_name" {
  description = "Elasticsearch node.name (for_each key, e.g. node-00 or master-00)."
  type        = string
}

variable "es_node_roles" {
  description = "Comma-separated Elasticsearch node.roles. Empty means all roles (default ES behaviour)."
  type        = string
  default     = ""
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

variable "discovery_ec2_s3_key" {
  description = "Object key of the cached discovery-ec2 plugin zip."
  type        = string
}

variable "discovery_ec2_s3_uri" {
  description = "s3:// URI of the cached discovery-ec2 plugin zip (written to node.env)."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups attached to the launch template (replaces the VPC default SG)."
  type        = list(string)
}

variable "aws_region" {
  description = "AWS region written to node.env for AWS CLI calls during init."
  type        = string
}

variable "es_initial_master_nodes" {
  description = "Comma-separated bootstrap node.name values (frozen; not the live cluster membership)."
  type        = string
}

variable "es_discovery_azs" {
  description = "Comma-separated AZs for discovery.ec2.availability_zones."
  type        = string
}

variable "es_bootstrap_secret_arn" {
  description = "Secrets Manager ARN of the Elasticsearch bootstrap password (prod)."
  type        = string
  default     = ""
}

variable "es_tls_secret_arn" {
  description = "Secrets Manager ARN of the Elasticsearch CA and per-node TLS JSON (prod)."
  type        = string
  default     = ""
}

variable "es_secrets_backend" {
  description = "Where nodes read bootstrap/TLS material: secretsmanager or s3."
  type        = string

  validation {
    condition     = contains(["secretsmanager", "s3"], var.es_secrets_backend)
    error_message = "es_secrets_backend must be \"secretsmanager\" or \"s3\"."
  }
}

variable "es_bootstrap_s3_key" {
  description = "S3 object key for the bootstrap password when es_secrets_backend is s3."
  type        = string
  default     = ""
}

variable "es_tls_s3_key" {
  description = "S3 object key for TLS JSON when es_secrets_backend is s3."
  type        = string
  default     = ""
}

variable "es_bootstrap_s3_uri" {
  description = "s3:// URI for the bootstrap password when es_secrets_backend is s3."
  type        = string
  default     = ""
}

variable "es_tls_s3_uri" {
  description = "s3:// URI for TLS JSON when es_secrets_backend is s3."
  type        = string
  default     = ""
}

variable "enable_ssm_core" {
  description = "Attach AmazonSSMManagedInstanceCore (needed for EventBridge/SSM eviction)."
  type        = bool
  default     = true
}

variable "enable_imds_eviction" {
  description = "Install an IMDS Spot-interruption poller that runs handle_spot_eviction.sh."
  type        = bool
  default     = false
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 8
}

variable "root_volume_device_name" {
  description = "Root volume device name in the launch template (AL2023: /dev/xvda)."
  type        = string
  default     = "/dev/xvda"
}

variable "es_expected_nodes" {
  description = "Expected Elasticsearch node count (data + masters) for eviction lock wait."
  type        = number
}

variable "eviction_lock_s3_key" {
  description = "S3 object key of the cluster eviction lock in the cache bucket."
  type        = string
}

variable "eviction_lock_wait_seconds" {
  description = "Max seconds a second concurrent Spot eviction waits for the first node to rejoin."
  type        = number
}

variable "eviction_log_s3_prefix" {
  description = "S3 key prefix for eviction audit JSON objects in the cache bucket."
  type        = string
}

variable "log_eviction_event_b64" {
  description = "Base64-encoded log_eviction_event.sh installed under /opt/zero."
  type        = string
}

variable "tags" {
  description = "Extra tags merged onto taggable resources."
  type        = map(string)
  default     = {}
}
