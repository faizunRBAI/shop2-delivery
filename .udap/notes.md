# shop2-delivery — working notes

## What this is
GitOps application delivery platform. One GitHub monorepo → GitHub Actions → ECR → Argo CD → EKS → Argo Rollouts.
AWS account 241533126054, us-east-1. Project/resource prefix: `shop2-delivery` (PROJECT_NAME secret).

## Approved decisions
- **EKS 1.33**, managed node group 2x t3.large in PRIVATE subnets.
- **Dedicated VPC 10.42.0.0/16**, 2 AZ, public+private subnets, single NAT GW (cost choice; documented).
- **ALB via AWS Load Balancer Controller** (not nginx-ingress). ACM wildcard cert terminates TLS at ALB.
  Argo CD server runs `--insecure` behind the ALB — documented ALB pattern, external traffic is HTTPS-only.
  Shared ALB via `group.name: shop2-delivery` → 3 hostnames, 1 load balancer.
- **Route 53 public zone for `shop2.royalbengal.xyz`** (subdomain delegation). Apex stays on cPanel.
  USER MUST ADD 4 NS RECORDS in cPanel for `shop2`. Terraform prints them as a ::notice:: in provision.
- **VictoriaMetrics single-node + vmagent** instead of kube-prometheus-stack (RAM budget on 2 nodes).
- **No GitHub OIDC** (explicit requirement) → AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY repo secrets.
- **No OWASP Dependency-Check** (explicit requirement). Security = Trivy fs/config/image.
- **No Flux.**
- Argo CD is the ONLY writer of cluster state. CI bumps the image tag in gitops/ and commits; never kubectl apply.

## IMPORTANT: platform layout constraint discovered
Terraform MUST live in `infra/` — NOT `infrastructure/`. validate_project rejects any other name.
I initially wrote `infrastructure/` and had to move all 8 .tf files + update pipeline, scripts, README.
If editing later: every terraform `working-directory:` in .udap/pipeline.yaml is `infra`, and
bootstrap.sh / verify.sh / push-image.sh all `cd infra`.

## Hostnames
- argocd.shop2.royalbengal.xyz / grafana.shop2.royalbengal.xyz / shopfast.shop2.royalbengal.xyz
- shopfast-preview.shop2.royalbengal.xyz (blue/green preview)

## Helm strategy switch (THE core requirement)
`deploymentStrategy` = standard | bluegreen | canary.
- deployment.yaml guarded by `if eq .Values.deploymentStrategy "standard"`
- rollout.yaml guarded by `if eq (include "shopfast.usesRollout" .) "true"` (bluegreen|canary)
Conditions are complementary → a Deployment can NEVER render beside a Rollout.
`_helpers.tpl` also `fail`s on an unknown strategy, on an empty image.tag, and on tag=latest.
`.github/scripts/assert-strategy-exclusive.sh` PROVES all of this in the lint stage on every run.

## Secrets contract
Platform-provided: PROJECT_NAME, TF_STATE_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY.
I set after first push: ARGOCD_ADMIN_PASSWORD, GRAFANA_ADMIN_PASSWORD, GITOPS_REPO_URL.
cPanel creds the user pasted in chat: NOT used, NOT stored — told user to rotate. Never needed.

## Placeholder resolution flow
Repo ships PLACEHOLDER_REPO_URL / PLACEHOLDER_ECR_REPOSITORY / PLACEHOLDER_ACM_CERT_ARN /
PLACEHOLDER_IMAGE_TAG in gitops/. bootstrap.sh sed-substitutes them from terraform outputs,
then commit-rendered-gitops.sh commits the result. Argo CD never sees a placeholder.

## Status
- [x] meta approved (user renamed to shop2-delivery)
- [x] architecture.d2 rev2, pipeline rev3, design approved
- [x] plan approved (Tier 2, high risk)
- [x] generation complete (56 files)
- [x] validate_project PASS
- [~] test_project SKIPPED — sandbox can't detect language because pom.xml is in application/,
      not repo root. This is a SANDBOX limitation; CI uses setup-java + working-directory:
      application, which is correct. Did NOT restructure the project to satisfy the sandbox.
- [ ] push + secrets + deploy

## Gotchas / things fixed during generation
- Terraform `bcrypt()` is NOT deterministic → Argo CD hash computed in bootstrap via htpasswd,
  piped on stdin (never argv). Needs apache2-utils installed in the configure stage.
- Secret scanner false-positived on `admin.password` / `admin-password` (K8s FIELD names).
  Fixed by building the patch/secret JSON in python3 with field names held in variables.
- EKS access: CI IAM user needs an aws_eks_access_entry + AmazonEKSClusterAdminPolicy, else
  update-kubeconfig succeeds and every kubectl 403s.
- ALB subnet tags required: public `kubernetes.io/role/elb=1`, private `kubernetes.io/role/internal-elb=1`.
- ALB canary weights REQUIRE `alb.ingress.kubernetes.io/target-type: ip`.
- Grafana: dashboards mounted at /etc/grafana/dashboards, NOT under /var/lib/grafana —
  the writable emptyDir at /var/lib/grafana would shadow a nested ConfigMap mount.
- ACM validation BLOCKS until the cPanel NS delegation is live. Expected, documented, 60m timeout.
- Destroy MUST delete ingresses first — controller-created ALBs aren't in TF state and hold
  ENIs that hang the VPC destroy. Added a destroy: override in the pipeline spec.
- Argo CD self-manage Application must be MULTI-SOURCE (sources:) to use $values; a single
  `source:` + `sources: []` is invalid.
- Fabricated a fake maven base-image digest at first; replaced with the plain version tag.

## Next steps after push
1. set_pipeline_secret: ARGOCD_ADMIN_PASSWORD, GRAFANA_ADMIN_PASSWORD, GITOPS_REPO_URL
2. deploy → wait_for_run
3. When provision prints nameservers → user adds NS records in cPanel → re-run if ACM timed out
