# ---------------------------------------------------------------------------
# EKS control plane, OIDC provider for IRSA, and a managed node group placed
# in the private subnets.
#
# OWNERSHIP BOUNDARY — READ BEFORE ADDING RESOURCES HERE
# ------------------------------------------------------
# Two actors touch this cluster:
#
#   1. THIS TERRAFORM — owns the VPC, the control plane, IAM, the node group
#      and the OIDC provider.
#   2. THE UDAP PLATFORM's aws/eks preparation step — runs BEFORE this
#      terraform on every deploy and installs the four core EKS addons.
#
# When both try to own the same object, terraform calls CreateAddon, AWS
# answers 409 ResourceInUseException, and the apply dies.
# resolve_conflicts_on_create does NOT help: it resolves CONFIGURATION
# conflicts for an addon terraform is creating, not the EXISTENCE conflict.
#
# The addons are therefore ADOPTED with import blocks rather than created.
# Import blocks are declarative, run during apply, and are a no-op once the
# resource is in state — so retries stay clean.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# --- Cluster IAM role ------------------------------------------------------

data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.project_name}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- Control plane ---------------------------------------------------------

resource "aws_security_group" "cluster" {
  name        = "${var.project_name}-eks-cluster-sg"
  description = "EKS control plane security group"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-eks-cluster-sg"
  }
}

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 14
}

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
    # This ALSO creates an access entry for the creating principal, which in
    # CI is the same IAM user the pipeline authenticates as. Declaring a
    # separate aws_eks_access_entry for that principal is therefore guaranteed
    # to fail with 409 — see the note further down.
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_cloudwatch_log_group.eks,
  ]
}

# --- IRSA OIDC provider ----------------------------------------------------

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

locals {
  oidc_provider_arn  = aws_iam_openid_connect_provider.eks.arn
  oidc_provider_host = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# --- Node group IAM role ---------------------------------------------------

data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.project_name}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# --- Managed node group ----------------------------------------------------

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-ng"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.private[*].id

  instance_types = [var.node_instance_type]
  disk_size      = var.node_disk_size
  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    workload = "platform"
  }

  lifecycle {
    # The node group is the scaling unit; desired_size may drift if a
    # future autoscaler is added. Version/type changes still apply.
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = {
    Name = "${var.project_name}-ng"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_route_table_association.private,
  ]
}

# --- Cluster access for the CI principal -----------------------------------
#
# There is deliberately NO aws_eks_access_entry / aws_eks_access_policy_
# association resource here.
#
# The CI pipeline authenticates as the same IAM user that creates the cluster,
# and access_config.bootstrap_cluster_creator_admin_permissions = true makes
# EKS create that principal's access entry automatically, with cluster-admin
# rights, at cluster creation time. Verified against the live cluster:
#
#   aws eks describe-access-entry --principal-arn <ci-user>
#     -> exists, tags {}, createdAt == cluster creation timestamp
#
# Declaring it again failed every apply with:
#   Error: creating EKS Access Entry (...): StatusCode: 409,
#   ResourceInUseException: The specified access entry resource is already in
#   use on this cluster.
#
# IF THE CI IDENTITY EVER CHANGES to an IAM principal that is NOT the cluster
# creator, kubectl will start returning 403 and you must add BOTH an
# aws_eks_access_entry and an aws_eks_access_policy_association (with
# AmazonEKSClusterAdminPolicy) for that new principal here.

# --- Core addons -----------------------------------------------------------
#
# ADOPTED, NOT CREATED — see the ownership note at the top of this file.
#
# All four addons are installed by the platform's aws/eks preparation step
# before this terraform runs; verified with `aws eks describe-addon`, they all
# carry the same Project/ManagedBy/Stack tags and the same creation timestamp.
#
# coredns is absent from the import list below ONLY because a previous partial
# apply already recorded it in terraform state, and importing an
# already-managed resource is an error. The other three never made it into
# state, so their CreateAddon calls kept returning 409 on every retry.
#
# Import ids are "<cluster-name>:<addon-name>".

import {
  to = aws_eks_addon.vpc_cni
  id = "${var.project_name}-eks:vpc-cni"
}

import {
  to = aws_eks_addon.kube_proxy
  id = "${var.project_name}-eks:kube-proxy"
}

import {
  to = aws_eks_addon.ebs_csi
  id = "${var.project_name}-eks:aws-ebs-csi-driver"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}
