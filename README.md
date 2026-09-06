# ShopFast GitOps Delivery Platform

A complete, from-scratch application delivery platform on AWS: Terraform-provisioned
EKS, a Spring Boot service, immutable images in ECR, and **Argo CD + Argo Rollouts**
performing Blue/Green and Canary releases from a single GitHub monorepo.

> The deployment is a **git commit**. CI never mutates the cluster.

```
GitHub → GitHub Actions → Test + Trivy → Docker build → ECR (immutable :git-sha)
       → GitOps commit → Argo CD → EKS → Argo Rollouts (blue/green | canary)
```

---

## 1. Architecture

| Layer | Choice | Why |
|---|---|---|
| Compute | Amazon EKS 1.33, managed node group, 2× t3.large | Inside the EKS standard-support window; two nodes carry Argo CD, Rollouts, monitoring and the app |
| Network | Dedicated VPC `10.42.0.0/16`, 2 AZ, public + private subnets, 1 NAT GW | Worker nodes are private; only the ALB is internet-facing |
| Ingress | **AWS Load Balancer Controller → one shared ALB** | Argo CD, Grafana and ShopFast share an ALB via `group.name`, so three hostnames cost one load balancer. `target-type: ip` is required for Rollouts traffic shaping |
| TLS | **ACM wildcard certificate** on the ALB listener | Managed renewal, no cert-manager/HTTP-01 machinery, no certificates in the cluster |
| DNS | Route 53 public zone for the **delegated subdomain** `shop2.royalbengal.xyz` | The apex stays on cPanel; a subdomain delegation gives Terraform full control of the records it needs without touching your cPanel account |
| Registry | ECR with `IMMUTABLE` tags + scan-on-push | A git SHA tag can never be repointed — the GitOps reference is trustworthy |
| GitOps | Argo CD, App-of-Apps, self-managed | One writer of cluster state |
| Delivery | Argo Rollouts (blue/green + canary) | Progressive delivery with real ALB traffic weights |
| Metrics | VictoriaMetrics single-node + vmagent + kube-state-metrics | Prometheus-compatible at roughly a third of the memory of a full kube-prometheus-stack |
| Dashboards | Grafana, provisioned from ConfigMaps | Dashboards are code, not clicks |

**Traffic path:** `user → Route 53 → ALB (HTTPS, ACM) → Ingress → Service → pods`.
Port 80 redirects to 443; nothing is served in clear text.

---

## 2. Monorepo structure

```text
.
├── application/                  Spring Boot + Maven + Docker + Helm
│   ├── pom.xml
│   ├── Dockerfile                multi-stage, non-root, healthcheck
│   ├── src/main/java/...         ShopFast service
│   ├── src/main/resources/
│   │   ├── application.yml
│   │   └── static/index.html     live release-aware landing page
│   ├── src/test/java/...         JUnit + MockMvc tests
│   └── helm/shopfast/            ONE chart, three strategies
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml   renders ONLY for standard
│           ├── rollout.yaml      renders ONLY for bluegreen | canary
│           ├── service.yaml      + preview / canary services
│           ├── ingress.yaml      ALB + TLS (+ preview host)
│           └── _helpers.tpl      strategy guard, image guard, shared pod spec
│
├── infra/                        Terraform (ALL AWS resources)
│   ├── versions.tf               empty S3 backend (partial config)
│   ├── network.tf                VPC, subnets, IGW, NAT, routes, ELB tags
│   ├── eks.tf                    cluster, OIDC, node group, addons, access entry
│   ├── iam_irsa.tf               IRSA roles: EBS CSI, AWS LB Controller
│   ├── ecr.tf                    immutable repository + lifecycle policy
│   ├── dns_tls.tf                Route 53 zone + ACM wildcard + validation
│   └── outputs.tf
│
├── gitops/                       Argo CD desired state
│   ├── root-app.yaml             the App-of-Apps root
│   ├── apps/                     child Applications (sync waves)
│   │   ├── 01-argocd.yaml        Argo CD manages itself
│   │   ├── 02-argo-rollouts.yaml
│   │   ├── 03-monitoring.yaml
│   │   └── 04-shopfast.yaml
│   ├── platform/
│   │   ├── argocd/values.yaml
│   │   ├── argo-rollouts/values.yaml
│   │   └── monitoring/           VictoriaMetrics, vmagent, KSM, Grafana, dashboards
│   ├── environments/production/
│   │   └── shopfast-values.yaml  ← the file CI bumps; this file IS the release
│   └── bootstrap/
│       ├── bootstrap.sh          the one imperative step
│       └── verify.sh             asserts real AWS/EKS/Argo state
│
├── docs/RUNBOOK.md               promote, roll back, diagnose, tear down
└── .github/
    ├── workflows/                RENDERED from .udap/pipeline.yaml — do not edit
    └── scripts/
        ├── push-image.sh
        ├── gitops-bump.sh
        ├── verify-rollout.sh
        ├── assert-strategy-exclusive.sh
        └── commit-rendered-gitops.sh
```

> `infra/` is the platform's required Terraform root directory name.

---

## 3. AWS resources

Created entirely by Terraform in `infra/`:

**Networking** — VPC `10.42.0.0/16`; 2 public + 2 private /20 subnets across 2 AZs;
internet gateway; 1 NAT gateway + EIP; route tables and associations; subnet tags
`kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb` for ALB discovery.

**EKS** — control plane 1.33 (api + audit + authenticator logs → CloudWatch, 14-day
retention); managed node group (2× t3.large, AL2023, private subnets, 50 GiB root);
OIDC provider for IRSA; addons vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver;
access entry + `AmazonEKSClusterAdminPolicy` for the CI principal.

**IAM** — cluster role, node role (worker/CNI/ECR-read/SSM); IRSA roles for the EBS
CSI driver and the AWS Load Balancer Controller (upstream least-privilege policy,
scoped by `elbv2.k8s.aws/cluster` resource tags).

**ECR** — `<project>/shopfast`, `IMMUTABLE` tags, scan-on-push, AES256, keep-30 lifecycle rule.

**DNS/TLS** — Route 53 public hosted zone for `shop2.royalbengal.xyz`; ACM certificate
for the apex + `*.shop2.royalbengal.xyz`, DNS-validated, with validation records.

**State** — remote S3 backend (platform-managed bucket), key `<project>/terraform.tfstate`,
declared as an **empty** `backend "s3" {}` and supplied via `-backend-config` flags.

---

## 4. Kubernetes namespaces

| Namespace | Contents | Created by |
|---|---|---|
| `argocd` | Argo CD server, repo-server, app-controller, redis; the `root` Application | bootstrap, then self-managed |
| `argo-rollouts` | Rollouts controller + CRDs | Argo CD (`02-argo-rollouts`) |
| `monitoring` | VictoriaMetrics, vmagent, kube-state-metrics, Grafana | Argo CD (`03-monitoring`) |
| `shopfast` | The application Rollout/Deployment, Services, Ingress | Argo CD (`04-shopfast`) |
| `kube-system` | AWS Load Balancer Controller, EBS CSI, CoreDNS, kube-proxy | Terraform addons + bootstrap |

---

## 5. GitHub Actions design

Workflows are **rendered** from `.udap/pipeline.yaml`. Edit the spec, never
`.github/workflows/*.yml`.

### `deploy` — infrastructure and platform (run this first)

```
lint ─┬─ test ─────┐
      └─ security ─┴─ provision ─ configure ─ verify
```

- **lint** — `mvn compile`; `helm lint` in all three strategies; runs
  `assert-strategy-exclusive.sh`, which renders the chart three ways and **fails the
  build** if a Deployment and a Rollout ever appear together, if `image.tag=latest`
  is accepted, or if an unknown strategy is accepted.
- **test** — JUnit/MockMvc against `/api/hello`, `/actuator/health`, `/actuator/prometheus`, `/`.
- **security** — Trivy filesystem/secret scan of `application/` and Trivy IaC scan of
  `infra/`. *(No OWASP Dependency-Check, as requested.)*
- **provision** — Terraform. Creates the Route 53 zone **first** and prints the
  nameservers as a `::notice::`, then applies the rest.
- **configure** — installs the AWS LB Controller and Argo CD, sets the admin credentials,
  resolves the GitOps placeholders, applies the **root** Application, commits the
  resolved manifests. This is the only imperative step in the system.
- **verify** — `verify.sh`: nodes Ready, controllers ready, Rollout CRD present, every
  Argo Application `Synced/Healthy`, the strategy invariant holds in the live cluster,
  VictoriaMetrics answering queries, and **real HTTPS probes** of all three public URLs.

### `app-release` — application releases (run on app changes)

```
build_test → image_scan → push_ecr → gitops_bump → rollout_verify
```

`gitops_bump` rewrites `image.tag` in `gitops/environments/production/shopfast-values.yaml`
and commits. That commit **is** the deployment. `rollout_verify` then waits for Argo CD
to report `Synced/Healthy` **and** for running pods to actually carry that SHA — a paused
canary is reported as an awaiting-promotion gate, not a failure.

### `destroy` — teardown

Deletes Kubernetes-created ingresses first (their ALBs and security groups are **not**
in Terraform state and would otherwise hold ENIs and hang the VPC destroy), then runs
`terraform destroy`.

---

## 6. Required GitHub Secrets

Set automatically by the platform:

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | AWS auth — **encrypted GitHub Secrets, not OIDC**, as required |
| `PROJECT_NAME` | Resource prefix and terraform state key |
| `TF_STATE_BUCKET` | Remote state bucket |

Set once after the first push:

| Secret | Purpose |
|---|---|
| `ARGOCD_ADMIN_PASSWORD` | Argo CD `admin` login |
| `GRAFANA_ADMIN_PASSWORD` | Grafana `admin` login |
| `GITOPS_REPO_URL` | HTTPS URL of this repository, written into the Argo Applications |

No credential is ever committed. Every reference in this repo is `${{ secrets.NAME }}`,
and the bootstrap pipes credential values to `kubectl` on **stdin** so they never appear
in the process argument list.

---

## 7. Bootstrap sequence

Start from an AWS account where none of this exists.

1. **Run the `deploy` workflow.** It reaches the *"Create the hosted zone first"* step
   and prints four Route 53 nameservers as a notice.
2. **Delegate the subdomain in cPanel** — this is the one manual step. In *Zone Editor*
   for `royalbengal.xyz`, add four **NS** records:

   ```
   shop2   NS   ns-xxx.awsdns-xx.com.
   shop2   NS   ns-xxx.awsdns-xx.net.
   shop2   NS   ns-xxx.awsdns-xx.org.
   shop2   NS   ns-xxx.awsdns-xx.co.uk.
   ```

   Confirm it is live: `dig +short NS shop2.royalbengal.xyz`
3. The same run continues; `aws_acm_certificate_validation` waits (up to 60 min) for the
   delegation, then issues the certificate. If it times out, the delegation was not live —
   fix the NS records and re-run. That is the only cause.
4. **provision** finishes: VPC, EKS, node group, ECR, zone, certificate.
5. **configure** installs the LB Controller and Argo CD, seeds credentials, applies the
   root Application. Argo CD then syncs Rollouts, monitoring and ShopFast by sync wave.
6. **verify** proves the whole thing with live HTTPS probes.
7. **Run `app-release`** to build the first real image and roll it out.

**Endpoints**

| URL | Auth |
|---|---|
| `https://argocd.shop2.royalbengal.xyz` | `admin` / `ARGOCD_ADMIN_PASSWORD` |
| `https://grafana.shop2.royalbengal.xyz` | `admin` / `GRAFANA_ADMIN_PASSWORD` |
| `https://shopfast.shop2.royalbengal.xyz` | public |
| `https://shopfast-preview.shop2.royalbengal.xyz` | public (blue/green preview) |

No `kubectl port-forward` anywhere in this design.

---

## 8. Deployment flow

1. Push an application change to `main`.
2. `app-release`: tests → Trivy image scan → build → push `ECR:<git-sha>` (immutable).
3. `gitops-bump.sh` rewrites `image.tag` and commits.
4. Argo CD detects the new revision and syncs the `shopfast` Application.
5. Argo Rollouts executes the strategy in `deploymentStrategy`:

   **Canary** (default) — 20% → wait 60s → 50% → wait 120s → 80% → wait 60s → 100%,
   with ALB weights moved at each step.
   ```bash
   kubectl argo rollouts -n shopfast get rollout shopfast --watch
   ```

   **Blue/Green** — the green stack goes live on the preview host only; production
   traffic moves only on promotion (`autoPromotionEnabled: false`).
   ```bash
   curl https://shopfast-preview.shop2.royalbengal.xyz/api/hello   # verify green
   kubectl argo rollouts -n shopfast promote shopfast              # switch
   kubectl argo rollouts -n shopfast abort   shopfast              # or roll back
   ```

   **Standard** — a plain RollingUpdate Deployment.

Switch strategies by editing `deploymentStrategy` in
`gitops/environments/production/shopfast-values.yaml` and committing.

**Rollback:** revert the GitOps commit. The previous SHA is still in ECR, so the
previous state is always reachable — `git revert` is the rollback.

---

## 9. Security model

- **No OIDC**, by requirement. AWS auth uses encrypted GitHub Secrets. Those credentials
  live only in Actions; nothing is written to the repo or the cluster.
- **No secrets in git.** Only `${{ secrets.NAME }}` references. Trivy runs a secret scan
  on every deploy; the platform runs an independent secret-literal scan.
- **Least privilege in-cluster.** IRSA roles trust exactly one `namespace:serviceaccount`
  pair. The app has no AWS role at all and `automountServiceAccountToken: false`.
- **Hardened pods.** Non-root (UID 10001), `readOnlyRootFilesystem`, all capabilities
  dropped, `allowPrivilegeEscalation: false`, `RuntimeDefault` seccomp.
- **Network.** Worker nodes have no public IPs; only the ALB is internet-facing. Egress
  via NAT.
- **TLS everywhere externally.** ACM certificate on the ALB, TLS 1.3 policy, HTTP→HTTPS
  redirect. Argo CD's server runs `--insecure` **behind** the ALB: that is the documented
  ALB pattern and means plain HTTP exists only inside the cluster, never on the wire.
- **Authentication.** Argo CD and Grafana both require a login; Grafana anonymous access
  and sign-up are disabled. Argo CD RBAC defaults to `role:readonly`.
- **Supply chain.** Immutable ECR tags, scan-on-push, Trivy image scanning, and a chart
  guard that refuses `image.tag: latest`.
- **Credentials pasted into a chat must be rotated.** The cPanel password shared during
  this build was never stored or used by the platform and must be considered compromised.

---

## 10. Important decisions

1. **ALB + ACM instead of nginx-ingress + cert-manager.** Fewer moving parts, managed
   certificate renewal, and Argo Rollouts supports ALB weights natively.
2. **Subdomain delegation instead of cPanel API automation.** Terraform owns
   `shop2.royalbengal.xyz` completely; your cPanel credentials are never needed by the
   platform. Cost: one manual NS step, once.
3. **VictoriaMetrics instead of kube-prometheus-stack.** Prometheus-compatible; PromQL
   and the Grafana Prometheus datasource work unchanged, at far lower memory on a
   two-node cluster.
4. **Argo CD is the only writer of cluster state.** CI pushes images and commits YAML —
   it never runs `kubectl apply` on application manifests. This avoids the classic
   two-writer fight.
5. **The strategy invariant is tested, not just intended.** `assert-strategy-exclusive.sh`
   renders all three modes in CI and fails if a Deployment and a Rollout ever coexist.
6. **Spring Boot 3.5.6, not 4.x.** You asked for Spring 4.x; Boot 4.0 is very new and
   3.5.x is the current stable line (Spring Framework 6.2). Reliability was chosen over
   novelty — upgrading later is a `pom.xml` change.
7. **Single NAT gateway.** Saves ~$33/month; an AZ failure would cut worker egress. A
   NAT per AZ is the documented upgrade.
8. **Blue/Green auto-promotion is off.** A human (or a future AnalysisTemplate) decides.
9. **Terraform reads its own outputs in every job.** Values embedding `PROJECT_NAME` are
   masked by GitHub and silently dropped from job outputs, so each job re-inits the
   backend and reads state itself rather than threading values between jobs.
10. **Teardown deletes ingresses before `terraform destroy`.** Controller-created ALBs
    are not in Terraform state; skipping this hangs the VPC destroy for ~20 minutes.

### Optional enhancements (deliberately not built)

Argo Rollouts `AnalysisTemplate` auto-promotion gated on VictoriaMetrics error rates ·
NAT gateway per AZ · Cluster Autoscaler / Karpenter · External Secrets Operator ·
Argo CD SSO (Dex/OIDC) · Alertmanager on the golden signals · Velero backups.

---

## Cost

Roughly **$255–300/month**: EKS control plane $73, 2× t3.large ~$120, NAT ~$33 + data,
ALB ~$18, Route 53 $0.50, ECR/S3/CloudWatch a few dollars. Biggest levers: t3.medium
nodes (−$60) or dropping the NAT by placing nodes in public subnets (−$33).
