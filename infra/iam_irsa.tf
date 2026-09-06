# ---------------------------------------------------------------------------
# IRSA roles for in-cluster controllers. Each role trusts ONLY the specific
# namespace/serviceaccount pair that needs it (least privilege).
#
# NOTE ON THE LOAD BALANCER
# -------------------------
# There is deliberately NO AWS Load Balancer Controller role here. The public
# entrypoint is an NLB created by the ingress-nginx controller's Service of
# type=LoadBalancer, which is handled by the in-tree AWS cloud provider running
# on the control plane and the kubelets. Those already hold the required
# elasticloadbalancing permissions through AmazonEKSClusterPolicy (control
# plane) and AmazonEKSWorkerNodePolicy (nodes), so no extra IAM principal and
# no IRSA binding is needed.
#
# This is a real reduction in blast radius: the ~200 lines of ELB/WAF/Shield
# permissions the ALB controller required are simply gone.
# ---------------------------------------------------------------------------

# --- EBS CSI driver --------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_host}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.project_name}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
