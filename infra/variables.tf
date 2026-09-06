variable "project_name" {
  description = "Branch-scoped project name used as the prefix for every AWS resource."
  type        = string
}

variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "base_domain" {
  description = "Delegated subdomain hosting the platform endpoints (Route 53 public zone)."
  type        = string
  default     = "shop2.royalbengal.xyz"
}

variable "vpc_cidr" {
  description = "CIDR block for the platform VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS control plane version. Must be inside the EKS standard support window."
  type        = string
  default     = "1.33"
}

variable "node_instance_type" {
  description = "Instance type for the managed node group."
  type        = string
  default     = "t3.large"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 4
}

variable "node_disk_size" {
  description = "EBS root volume size in GiB for each worker node."
  type        = number
  default     = 50
}
