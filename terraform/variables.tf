variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
}

variable "aws_profile" {
  description = "AWS profile credentials"
  type        = string
}

variable "cluster_name" {
  description = "Name prefix for cluster resources (VPC, subnets, etc.)."
  type        = string
}

variable "environment" {
  description = "prod = multi-AZ endpoints, Secrets Manager, EventBridge/SSM eviction. dev = single-AZ ec2 endpoint, secrets on S3, IMDS eviction poller."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["prod", "dev"], var.environment)
    error_message = "environment must be \"prod\" or \"dev\"."
  }
}

variable "vpc_cidr_block" {
  description = "IPv4 CIDR block for the cluster VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones that each receive one private subnet and one ASG-of-1 node."
  type        = list(string)
}

variable "default_tags" {
  description = "Tags applied to every taggable resource via the provider default_tags block."
  type        = map(string)
  default = {
    Project = "Spot-Stateful-Cluster"
  }
}

variable "nodes_total" {
  description = "Number of data (or all-in-one) ASG-of-1 nodes, round-robin across availability_zones. When dedicated_masters is true this is data nodes only."
  type        = number

  validation {
    condition     = var.nodes_total >= 1 && floor(var.nodes_total) == var.nodes_total
    error_message = "nodes_total must be a positive integer."
  }
}

variable "dedicated_masters" {
  description = "If true, create one On-Demand dedicated master per AZ and strip the master role from nodes_total. If false, nodes_total members have all roles (current behaviour)."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "EC2 instance type for data / all-in-one nodes when spot_instance_types is empty, and for the launch template default (arm64/Graviton, e.g. m6g.large)."
  type        = string
}

variable "spot_instance_types" {
  description = "Ordered Spot instance types for data-node mixed instances (same AZ). Empty = [instance_type]. Prefer capacity-optimized-prioritized so list order is preference."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.spot_instance_types) == 0 || length(var.spot_instance_types) == length(distinct(var.spot_instance_types))
    error_message = "spot_instance_types must not contain duplicates."
  }
}

variable "spot_allocation_strategy" {
  description = "Spot allocation strategy for data-node ASGs (capacity-optimized-prioritized uses spot_instance_types order as preference)."
  type        = string
  default     = "capacity-optimized-prioritized"

  validation {
    condition = contains([
      "lowest-price",
      "capacity-optimized",
      "capacity-optimized-prioritized",
      "price-capacity-optimized",
    ], var.spot_allocation_strategy)
    error_message = "spot_allocation_strategy must be one of: lowest-price, capacity-optimized, capacity-optimized-prioritized, price-capacity-optimized."
  }
}

variable "master_instance_type" {
  description = "EC2 instance type for dedicated master nodes when dedicated_masters is true (arm64/Graviton, e.g. t4g.medium)."
  type        = string
  default     = "t4g.medium"
}

variable "data_volume_size_gb" {
  description = "Size in GiB of the durable data EBS volume for data / all-in-one nodes."
  type        = number
  default     = 100

  validation {
    condition     = var.data_volume_size_gb >= 1 && floor(var.data_volume_size_gb) == var.data_volume_size_gb
    error_message = "data_volume_size_gb must be a positive integer."
  }
}

variable "master_data_volume_size_gb" {
  description = "Size in GiB of the durable volume for dedicated master nodes (cluster state only)."
  type        = number
  default     = 30

  validation {
    condition     = var.master_data_volume_size_gb >= 1 && floor(var.master_data_volume_size_gb) == var.master_data_volume_size_gb
    error_message = "master_data_volume_size_gb must be a positive integer."
  }
}

variable "data_volume_type" {
  description = "EBS volume type for each node's durable data volume."
  type        = string
  default     = "gp3"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB for each instance (AMI minimum may force a floor; keep small for cost)."
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size_gb >= 8 && floor(var.root_volume_size_gb) == var.root_volume_size_gb
    error_message = "root_volume_size_gb must be an integer >= 8."
  }
}

variable "elasticsearch_version" {
  description = "Elasticsearch version to cache in the S3 artifact bucket."
  type        = string
  default     = "9.4.4"
}

variable "elasticsearch_arch" {
  description = "Elasticsearch Linux architecture suffix (e.g. linux-aarch64, linux-x86_64)."
  type        = string
  default     = "linux-aarch64"
}

variable "eviction_lock_wait_seconds" {
  description = "Max seconds a second concurrent Spot eviction waits for the first node to rejoin (S3 lock age cap). Spot interruption is ~120s; keep this low enough to still stop ES and unmount (~40s)."
  type        = number
  default     = 60

  validation {
    condition     = var.eviction_lock_wait_seconds >= 0 && floor(var.eviction_lock_wait_seconds) == var.eviction_lock_wait_seconds
    error_message = "eviction_lock_wait_seconds must be a non-negative integer."
  }
}

variable "ingest_client_cidrs" {
  description = "Public IPv4 CIDRs allowed to reach the ingest gateway (Filebeat/Logstash/humans). Non-empty in dev creates the gateway; empty skips it."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.ingest_client_cidrs : can(cidrhost(c, 0))])
    error_message = "ingest_client_cidrs must be IPv4 CIDRs (e.g. 203.0.113.10/32)."
  }
}

variable "ingest_gateway_instance_type" {
  description = "On-Demand instance type for the dev ingest gateway (arm64/Graviton)."
  type        = string
  default     = "t4g.nano"
}

variable "es_initial_master_nodes" {
  description = "Bootstrap node.name values when dedicated_masters is false. Ignored when dedicated_masters is true (masters are master-00.. per AZ). Do not change after the cluster exists."
  type        = list(string)
  default     = ["node-00", "node-01", "node-02"]

  validation {
    condition = alltrue([
      for n in var.es_initial_master_nodes : can(regex("^node-[0-9]{2}$", n))
    ]) && length(var.es_initial_master_nodes) > 0
    error_message = "es_initial_master_nodes must be a non-empty list of names like node-00."
  }
}