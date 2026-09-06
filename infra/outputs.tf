output "eks_cluster_name" {
  description = "EKS cluster name (consumed by the configure and verify stages)."
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_version" {
  description = "Kubernetes version of the control plane."
  value       = aws_eks_cluster.main.version
}

output "ecr_repository_url" {
  description = "ECR repository URL for the ShopFast image."
  value       = aws_ecr_repository.shopfast.repository_url
}

output "vpc_id" {
  description = "Platform VPC id."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnets used by internet-facing load balancers."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnets hosting the EKS worker nodes."
  value       = aws_subnet.private[*].id
}

output "alb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller."
  value       = aws_iam_role.alb_controller.arn
}

output "acm_certificate_arn" {
  description = "Validated wildcard ACM certificate ARN used by the ALB listeners."
  value       = aws_acm_certificate_validation.platform.certificate_arn
}

output "route53_zone_id" {
  description = "Hosted zone id for the delegated platform subdomain."
  value       = aws_route53_zone.platform.zone_id
}

output "route53_nameservers" {
  description = "Add these as NS records for the 'shop2' subdomain in cPanel."
  value       = aws_route53_zone.platform.name_servers
}

output "base_domain" {
  description = "Delegated base domain for platform endpoints."
  value       = var.base_domain
}

output "argocd_url" {
  description = "Public Argo CD dashboard URL."
  value       = "https://argocd.${var.base_domain}"
}

output "grafana_url" {
  description = "Public Grafana URL."
  value       = "https://grafana.${var.base_domain}"
}

output "shopfast_url" {
  description = "Public ShopFast application URL."
  value       = "https://shopfast.${var.base_domain}"
}
