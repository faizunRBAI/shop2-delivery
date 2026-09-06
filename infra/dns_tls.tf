# ---------------------------------------------------------------------------
# DNS + TLS.
#
# The apex domain (royalbengal.xyz) stays on cPanel. Terraform creates a public
# Route 53 hosted zone for the DELEGATED subdomain shop2.royalbengal.xyz and a
# wildcard ACM certificate validated with DNS records in that zone.
#
# MANUAL PREREQUISITE (one time): after the first apply prints the zone's four
# nameservers, add them as NS records for the `shop2` subdomain in the cPanel
# DNS editor. ACM validation cannot complete until that delegation is live.
# ---------------------------------------------------------------------------

resource "aws_route53_zone" "platform" {
  name          = var.base_domain
  comment       = "Delegated subdomain for ${var.project_name} platform endpoints"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-zone"
  }
}

resource "aws_acm_certificate" "platform" {
  domain_name               = var.base_domain
  subject_alternative_names = ["*.${var.base_domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project_name}-cert"
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.platform.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = aws_route53_zone.platform.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# This resource BLOCKS until the certificate is issued, which requires the
# cPanel NS delegation to be in place. A timeout here means the delegation
# has not propagated yet - it is not a Terraform defect.
resource "aws_acm_certificate_validation" "platform" {
  certificate_arn         = aws_acm_certificate.platform.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  timeouts {
    create = "60m"
  }
}
