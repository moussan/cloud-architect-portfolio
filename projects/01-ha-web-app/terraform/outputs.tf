output "alb_dns_name" {
  description = "DNS name of the ALB"
  value       = aws_lb.this.dns_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
