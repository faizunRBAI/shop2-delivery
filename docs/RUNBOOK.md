# Operations Runbook

Everything here assumes `aws eks update-kubeconfig --name shop2-delivery-eks --region us-east-1`.
Install the Rollouts plugin once: `kubectl krew install argo-rollouts`.

---

## Promote a Blue/Green release

```bash
# 1. The green stack is live on the preview host only.
curl -s https://shopfast-preview.shop2.royalbengal.xyz/api/hello | jq

# 2. Confirm the rollout is paused awaiting promotion.
kubectl argo rollouts -n shopfast get rollout shopfast

# 3. Switch production traffic.
kubectl argo rollouts -n shopfast promote shopfast

# 4. Or abort and keep the current version.
kubectl argo rollouts -n shopfast abort shopfast
```

## Watch a Canary

```bash
kubectl argo rollouts -n shopfast get rollout shopfast --watch
```

Weights advance 20 → 50 → 80 → 100 with pauses. To see the split from outside:

```bash
for i in $(seq 1 20); do
  curl -s https://shopfast.shop2.royalbengal.xyz/api/hello | jq -r .version
done | sort | uniq -c
```

The same split is on the **ShopFast — Delivery & Rollouts** Grafana dashboard.

---

## Roll back

The GitOps commit is the release, so reverting it is the rollback. The previous image
is still in ECR (immutable tags), so nothing needs rebuilding.

```bash
git revert <the deploy commit>
git push origin main
```

Argo CD syncs the previous SHA. For an emergency in-cluster undo:

```bash
kubectl argo rollouts -n shopfast undo shopfast
```

⚠️ `undo` diverges the cluster from git; Argo's `selfHeal` will pull it back. Follow up
with the revert commit so git and the cluster agree.

---

## Change deployment strategy

Edit `gitops/environments/production/shopfast-values.yaml`:

```yaml
deploymentStrategy: bluegreen   # standard | bluegreen | canary
```

Commit. Argo CD replaces the workload — the chart guarantees a Deployment and a Rollout
never coexist.

---

## Diagnose: application not updating

```bash
# 1. Did Argo see the commit?
kubectl -n argocd get application shopfast \
  -o jsonpath='{.status.sync.revision}{"\n"}'

# 2. Sync/health and any error message.
kubectl -n argocd get application shopfast \
  -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
kubectl -n argocd get application shopfast \
  -o jsonpath='{.status.conditions[*].message}{"\n"}'

# 3. Is the rollout paused (expected) or degraded (not)?
kubectl argo rollouts -n shopfast get rollout shopfast

# 4. Pod-level truth.
kubectl -n shopfast get pods -o wide
kubectl -n shopfast logs -l app.kubernetes.io/name=shopfast --tail=100
```

`ImagePullBackOff` → the tag in the values file is not in ECR; check the `push_ecr` job.

---

## Diagnose: a URL returns 502/503

```bash
# Does the ingress have an ALB?
kubectl -n shopfast get ingress shopfast \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'

# Is the LB controller healthy and what did it say?
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=100

# Are the target groups healthy? (503 is usually "no healthy targets")
kubectl -n shopfast describe ingress shopfast
kubectl -n shopfast get endpoints
```

Common causes: readiness probe failing (the pod is up but not Ready), a missing
`kubernetes.io/role/elb` subnet tag, or the ACM certificate ARN missing from the ingress
annotation.

---

## Diagnose: Argo CD dashboard unreachable

```bash
kubectl -n argocd get ingress argocd-server
kubectl -n argocd get pods
dig +short argocd.shop2.royalbengal.xyz
dig +short NS shop2.royalbengal.xyz     # is the cPanel delegation still live?
```

If DNS resolves but TLS fails, the ACM certificate is not attached — check
`alb.ingress.kubernetes.io/certificate-arn` on the ingress.

---

## Reset the Argo CD admin password

```bash
HASH=$(htpasswd -nbBC 10 "" 'NEW_PASSWORD' | tr -d ':\n' | sed 's/^\$2y/\$2a/')
kubectl -n argocd patch secret argocd-secret \
  -p "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"
kubectl -n argocd rollout restart deployment argocd-server
```

Also update the `ARGOCD_ADMIN_PASSWORD` GitHub secret so the next bootstrap agrees.

---

## Metrics not appearing in Grafana

```bash
# Is vmagent scraping? Look for the shopfast pods as targets.
kubectl -n monitoring logs deploy/vmagent --tail=100

# Query VictoriaMetrics directly.
kubectl -n monitoring exec statefulset/victoriametrics -- \
  wget -qO- 'http://127.0.0.1:8428/api/v1/query?query=up'

# Does the app expose metrics at all?
kubectl -n shopfast exec deploy/shopfast -- curl -s localhost:8080/actuator/prometheus | head
```

Scraping depends on the pod annotations `prometheus.io/scrape|path|port`, which the chart
sets when `metrics.enabled: true`.

---

## Teardown

Use the platform Destroy action (runs the rendered `destroy` workflow). Order matters:
Kubernetes-created ALBs and their security groups are **not** in Terraform state, so
delete the ingresses first or `terraform destroy` will hang on the VPC.

```bash
kubectl delete ingress --all -A
kubectl -n argocd delete applications --all
# then run the destroy workflow
```
