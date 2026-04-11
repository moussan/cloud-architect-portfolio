################################################################################
# Compute Module — Outputs
#
# These outputs are consumed by:
# - Database module (pass ASG SG ID to allow ingress on 3306/5432)
# - DNS module (ALB DNS name for Route 53 alias record)
# - Monitoring module (ALB ARN for CloudWatch alarms)
# - CI/CD pipeline (ASG name for deployment scripts)
################################################################################

output "asg_name" {
  description = "Auto Scaling Group name. Used by CI/CD deployment scripts and Instance Refresh triggers."
  value       = aws_autoscaling_group.main.name
}

output "asg_arn" {
  description = "Auto Scaling Group ARN. Used in CloudWatch alarm configurations and IAM policies."
  value       = aws_autoscaling_group.main.arn
}

output "launch_template_id" {
  description = "Launch Template ID. Reference this when setting up EC2 Image Builder AMI distribution or triggering Instance Refresh."
  value       = aws_launch_template.main.id
}

output "launch_template_latest_version" {
  description = "Latest Launch Template version number. Useful for audit and debugging."
  value       = aws_launch_template.main.latest_version
}

output "alb_arn" {
  description = "ALB ARN. Used for CloudWatch alarm dimensions (TargetGroup metrics require ALB ARN suffix)."
  value       = aws_lb.main.arn
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix. Required for CloudWatch ALB metrics (e.g., RequestCount, TargetResponseTime)."
  value       = aws_lb.main.arn_suffix
}

output "alb_dns_name" {
  description = "ALB DNS name. Create a Route 53 alias record pointing to this value."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID. Required for Route 53 alias records (alias.evaluate_target_health)."
  value       = aws_lb.main.zone_id
}

output "target_group_arn" {
  description = "Target Group ARN. Used in CloudWatch alarms for HealthyHostCount and RequestCountPerTarget."
  value       = aws_lb_target_group.main.arn
}

output "target_group_arn_suffix" {
  description = "Target Group ARN suffix. Required for custom CloudWatch metrics on the target group."
  value       = aws_lb_target_group.main.arn_suffix
}

output "alb_security_group_id" {
  description = "ALB Security Group ID. Pass to WAF WebACL association or other components that need to reference the ALB SG."
  value       = aws_security_group.alb.id
}

output "asg_security_group_id" {
  description = "ASG instance Security Group ID. Pass to the database module to allow ingress from the application tier."
  value       = aws_security_group.asg.id
}

output "instance_role_arn" {
  description = "IAM role ARN for EC2 instances. Reference this in KMS key policies and resource-based policies that need to grant access to instances."
  value       = aws_iam_role.instance.arn
}

output "instance_profile_arn" {
  description = "IAM Instance Profile ARN. Can be referenced in other Launch Templates or Terraform modules that need the same instance permissions."
  value       = aws_iam_instance_profile.instance.arn
}

output "ebs_kms_key_arn" {
  description = "KMS CMK ARN used for EBS encryption. Pass to snapshot copy operations or cross-account AMI sharing configurations."
  value       = aws_kms_key.ebs.arn
}

output "ebs_kms_key_id" {
  description = "KMS CMK key ID (short form). Useful for AWS CLI commands."
  value       = aws_kms_key.ebs.key_id
}
