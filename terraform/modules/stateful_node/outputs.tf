output "asg_name" {
  description = "Name of the Auto Scaling Group."
  value       = aws_autoscaling_group.this.name
}

output "asg_arn" {
  description = "ARN of the Auto Scaling Group."
  value       = aws_autoscaling_group.this.arn
}

output "launch_template_id" {
  description = "ID of the launch template."
  value       = aws_launch_template.this.id
}

output "availability_zone" {
  description = "Availability zone this node is pinned to."
  value       = var.availability_zone
}

output "data_volume_id" {
  description = "ID of the durable data EBS volume paired to this ASG-of-1."
  value       = aws_ebs_volume.data.id
}

output "instance_profile_name" {
  description = "IAM instance profile name attached to the launch template."
  value       = aws_iam_instance_profile.this.name
}
