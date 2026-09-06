# Operations Runbook

Everything here assumes `aws eks update-kubeconfig --name shop2-delivery-eks --region us-east-1`.
Install the Rollouts plugin once: `kubectl krew install argo-rollouts`.

---

## DNS and TLS model — read this first

This platform does **not** use Route 53 or ACM. The domain is served by a cPanel zone
whose editor offers no `NS` record type, so subdomain delegation (and therefore
DNS-validated ACM certificates) is impossible.

Instead:

- **One NLB**, created by the `ingress-nginx-controller` Service. Its hostname is stable
  for the life of the cluster.
- **Three CNAME records**, created by hand in cPanel, all pointing at that hostname.
- **cert-manager** issues and renews Let's Encrypt certificates over the HTTP-01
  challenge — no DNS API access required.

Get the CNAME target at any time:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```

| cPanel record | Type | Value |
|---|---|---|
| `argocd.shop2` | CNAME | *(NLB hostname)* |
| `grafana.shop2` | CNAME | *(NLB hostname)* |
| `shopfast.shop2` | CNAME | *(NLB hostname)* |
| `shopfast-preview.shop2` | CNAME | *(NLB hostname)* — only needed for Blue/Green |

> **Let's Encrypt rate limits:** 50 certificates per registered domain per week, and
> **5 duplicate certificates per week**. If you are debugging issuance, switch
> `clusterIssuer` to `letsencrypt-staging` first — burning the duplicate limit locks a
> hostname out for seven days.

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

Weights advance 20 → 50 → 80 → 100 with pauses. The split is applied by the Argo Rollouts
**NGINX traffic router**, which creates a managed canary Ingress alongside the stable one:

```bash
# The controller-owned canary ingress and its current weight.
kubectl -n shopfast get ingress
kubectl -n shopfast get ingress shopfast-shopfast-canary \
  -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-weight}{"\n"}'
```

To see the split from outside:

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

## Diagnose: a URL returns 502/503/404

Work outside-in. The first question is always *"is this DNS, TLS, or the app?"*

```bash
# 1. Does DNS point at our load balancer?
dig +short shopfast.shop2.royalbengal.xyz
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
#    -> the two must agree. If not, fix the cPanel CNAME.

# 2. Bypass DNS entirely: does nginx route correctly by Host header?
kubectl -n ingress-nginx run probe --rm -i --restart=Never \
  --image=curlimages/curl:8.11.0 -- \
  curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Host: shopfast.shop2.royalbengal.xyz' \
  http://ingress-nginx-controller.ingress-nginx.svc/actuator/health
#    200 or 308 => the platform is fine and the problem is DNS/TLS.

# 3. Is the ingress registered and are there endpoints behind it?
kubectl -n shopfast describe ingress shopfast
kubectl -n shopfast get endpoints

# 4. What did the controller actually do?
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=100
```

Common causes: the readiness probe failing (pod up but not Ready → 503), a missing
`kubernetes.io/role/elb` subnet tag (no NLB at all), or a certificate not yet issued.

---

## Diagnose: TLS certificate not issued

HTTP-01 requires that the public DNS name already resolves to the NLB **and** that port 80
is reachable. Order of investigation:

```bash
# 1. Certificate objects and their readiness.
kubectl get certificate -A

# 2. Why is it not Ready? Walk the chain: Certificate -> Order -> Challenge.
kubectl describe certificate <name> -n <namespace>
kubectl get order -A
kubectl describe challenge -A

# 3. The issuer must have a registered ACME account.
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-prod

# 4. cert-manager's own account of events.
kubectl -n cert-manager logs deploy/cert-manager --tail=150
```

| Symptom in the Challenge | Meaning | Fix |
|---|---|---|
| `NXDOMAIN` / no such host | the cPanel CNAME is missing | add the CNAME |
| connection timeout on :80 | DNS points somewhere else | verify the CNAME target |
| `404` on the challenge path | a global HTTPS redirect is on | `ssl-redirect` must stay `false` in the controller config |
| `too many certificates` | Let's Encrypt rate limit | switch to `letsencrypt-staging`, wait out the week |

The global redirect point is worth repeating: `controller.config.ssl-redirect` must remain
`"false"`. Redirects are set per-ingress, which ingress-nginx exempts for the ACME path.

---

## Diagnose: Argo CD dashboard unreachable

```bash
kubectl -n argocd get ingress argocd-server
kubectl -n argocd get pods
kubectl get certificate -n argocd
dig +short argocd.shop2.royalbengal.xyz
```

If you get a 502 specifically, check that `server.insecure` is still `true`: the chart
points the ingress at the server's port 80 only when it is, and pointing plain HTTP at
port 443 produces exactly that error.

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
the NLB is created by the AWS cloud provider from the ingress-nginx Service and is **not**
in Terraform state, so it must be deleted first or `terraform destroy` hangs on the VPC
waiting for ENIs that nothing will release.

```bash
kubectl -n argocd delete applications --all
kubectl delete ingress --all -A
kubectl -n ingress-nginx delete svc ingress-nginx-controller
# then run the destroy workflow
```

The destroy workflow already does this; the manual sequence is for when it is interrupted.
