# ---------------------------------------------------------------------------
# DNS + TLS — deliberately NOT managed by AWS.
#
# WHY THIS FILE IS ALMOST EMPTY
# -----------------------------
# The apex domain (royalbengal.xyz) is registered with and served by a cPanel
# host whose Zone Editor does NOT offer the NS record type. Delegating the
# shop2 subdomain to a Route 53 hosted zone is therefore impossible, and ACM
# only validates certificates via DNS or email — neither of which we can drive.
#
# The design consequence:
#
#   * No aws_route53_zone, no aws_acm_certificate. TLS is issued IN-CLUSTER by
#     cert-manager from Let's Encrypt using the HTTP-01 challenge, which is
#     answered over port 80 on the public load balancer and needs no DNS API.
#
#   * The public entrypoint is a Network Load Balancer created by the
#     ingress-nginx controller's Service (type=LoadBalancer). Its hostname is
#     stable across ingress changes, which matters because the DNS records
#     pointing at it are maintained BY HAND in cPanel.
#
#   * The operator adds three CNAME records in cPanel, once:
#
#         argocd.shop2    CNAME  <nlb-hostname>
#         grafana.shop2   CNAME  <nlb-hostname>
#         shopfast.shop2  CNAME  <nlb-hostname>
#
#     The verify stage prints the exact hostname to paste.
#
# The base domain is still a Terraform variable because the Helm values and the
# verify stage derive every hostname from it — it is just no longer a zone we
# own in this account.
# ---------------------------------------------------------------------------

# Nothing to declare here. This file is retained (rather than deleted) as the
# documented home of the DNS/TLS decision, so the next engineer reading infra/
# finds the reasoning instead of wondering where the certificate went.
