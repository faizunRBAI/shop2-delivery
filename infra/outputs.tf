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
  description = "Public subnets used by the internet-facing NLB."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnets hosting the EKS worker nodes."
  value       = aws_subnet.private[*].id
}

# ---------------------------------------------------------------------------
# There is deliberately no acm_certificate_arn / route53_zone_id /
# route53_nameservers output. TLS is issued in-cluster by cert-manager and DNS
# is maintained by hand in cPanel; see infra/dns_tls.tf for the reasoning.
#
# The public entrypoint is the NLB hostname on the ingress-nginx Service, which
# only exists once Argo CD has synced the controller. The verify stage reads it
# with kubectl and prints it as the CNAME target.
# ---------------------------------------------------------------------------

output "base_domain" {
  description = "Base domain for platform endpoints (records are managed in cPanel)."
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
