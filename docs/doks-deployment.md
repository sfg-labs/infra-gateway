# Deploying the Gateway to DigitalOcean Kubernetes (DOKS)

This document records how the sfg-labs gateway (APISIX + Zitadel) was adapted from its
original **self-managed k3s (Cantech Mumbai)** design to run on a **managed DigitalOcean
Kubernetes** cluster, deployed through a **GitHub Actions CD pipeline** with all secrets
sourced from **GitHub Secrets**.

---

## 1. Goal & target environment

| | |
|---|---|
| Goal | Deploy the gateway + identity provider to Kubernetes via CD, secrets from GitHub Secrets |
| Cluster | DigitalOcean Kubernetes (DOKS), region `sgp1`, Kubernetes `v1.35.5` |
| Topology | Single node (~3.9 vCPU / ~14 GB), CNI Cilium |
| Storage | `do-block-storage` (default StorageClass) |
| Gateway exposure | DigitalOcean LoadBalancer (public IP) |
| Auth DB | In-cluster PostgreSQL (no external/managed DB) |

The repo's original deploy path (`helm/deploy.sh` + Helm values) targeted k3s with a NodePort
gateway and an external Postgres VM on a private VLAN. Those assumptions do not hold on DOKS,
which is what this work addressed.

---

## 2. What we added

| File | Purpose |
|---|---|
| `.github/workflows/cd.yaml` | CD pipeline: auth to DOKS, create k8s Secrets from GitHub Secrets, deploy Postgres, run `helm/deploy.sh`, report state |
| `k8s/namespaces.yaml` | Declarative `sfg-gateway` / `sfg-apps` / `sfg-labs` namespaces |
| `helm/zitadel/postgres.yaml` | In-cluster PostgreSQL (StatefulSet + Service + PVC) for Zitadel |
| `docs/doks-deployment.md` | This document |

## 3. What we changed

| File | Change |
|---|---|
| `helm/zitadel/values.yaml` | DB `Host` → in-cluster service; fixed `Database.Postgres.User`/`Admin` nested structure; moved DB password env to **top-level `.Values.env`**; `replicaCount: 1` |
| `helm/apisix/values.yaml` | `service.type: LoadBalancer` (was the ignored `gateway.type`); `replicaCount: 1`; added `sfg-labs` to ingress-controller `watchNamespaces` |
| `helm/deploy.sh` | Replaced inline namespace creation with `kubectl apply -f k8s/namespaces.yaml` (now also creates `sfg-labs`) |
| `routes/*.yaml` (14 files) | Co-located each `ApisixRoute` in its backend's namespace and removed `serviceNamespace`; split `public.yaml` into one route per namespace |

---

## 4. Architecture decisions

- **In-cluster Postgres, official image.** Used `postgres:16-alpine` (the same image the repo's
  `docker-compose.yml` uses) via a plain StatefulSet rather than the Bitnami chart, because
  Bitnami's free Docker images were deprecated/relocated in 2025 and the chart defaults can fail
  to pull. `POSTGRES_USER=zitadel` makes `zitadel` the superuser, so Zitadel uses it for both its
  runtime and admin (init/migration) connections. The password is read from the `zitadel-db`
  Secret — never committed.

- **LoadBalancer exposure.** DOKS provisions a DigitalOcean LoadBalancer for a `Service` of
  `type: LoadBalancer`, giving a stable public IP — replacing the k3s NodePort `:30080` pattern.

- **Namespace-co-located routes.** The installed APISIX ingress controller's `ApisixRoute`
  (`apisix.apache.org/v2`) routes only to Services in the route's **own** namespace; there is no
  `backends[].serviceNamespace`. So each route lives with its backend: NMA/Baithak/CMS in
  `sfg-apps`, Suwalka in `sfg-labs`, Zitadel in `sfg-gateway`. The ingress controller watches all
  three namespaces.

- **Secrets via GitHub Secrets → k8s Secrets.** The pipeline reads GitHub Secrets and materializes
  Kubernetes Secrets at deploy time (idempotent `kubectl apply`). Nothing sensitive is stored in
  the repo. Namespaces stay declarative; only Secrets are created imperatively.

---

## 5. Issues encountered and fixes

The deploy was iterated through the CD pipeline; each failure and its fix:

### 5.1 `doctl kubernetes cluster kubeconfig save` → 403
The token embedded in the downloaded kubeconfig authenticates `kubectl` to the cluster API
server but is **not** authorized for DigitalOcean's management API. 
**Fix:** dropped `doctl`; store the full kubeconfig as the `DOKS_KUBECONFIG` secret and write it to
a file, setting `KUBECONFIG` for all steps. (`DIGITALOCEAN_ACCESS_TOKEN` / `DOKS_CLUSTER_ID` are no
longer used.)

### 5.2 Zitadel `sfg-zitadel-init` job timed out (`DeadlineExceeded`)
The pre-install hook jobs (`init`, `setup`) inject **`.Values.env`** (via the chart's
`zitadel.dbEnv` helper) — not `.Values.zitadel.env`. The DB password env was nested under
`zitadel.env`, so the init job connected to Postgres with an empty password and retried until the
deadline. 
**Fix:** moved the `ZITADEL_DATABASE_POSTGRES_USER_PASSWORD` / `..._ADMIN_PASSWORD` env entries to
the **top-level `env:`** in `helm/zitadel/values.yaml`.

### 5.3 `kubectl apply -f routes/` → `unknown field "serviceNamespace"`
The installed `ApisixRoute` CRD's backend schema supports only
`serviceName, servicePort, weight, subset, resolveGranularity` — strict decoding rejected every
route's `serviceNamespace`. 
**Fix:** removed `serviceNamespace` and moved each route into its backend's namespace; split
`public.yaml` into three routes (one per namespace). Verified all 15 routes apply.

### 5.4 Gateway came up as NodePort, not LoadBalancer
`gateway.type: LoadBalancer` is not a key this apisix chart recognizes (Helm silently ignores
unknown keys), so the gateway defaulted to NodePort. 
**Fix:** set `service.type: LoadBalancer` (the chart's actual key).

---

## 6. Required GitHub Secrets

Add under **repo → Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `DOKS_KUBECONFIG` | Full contents of the DigitalOcean cluster kubeconfig file |
| `ZITADEL_DB_PASSWORD` | Postgres password for the `zitadel` role (any strong value) |
| `ZITADEL_MASTERKEY` | Zitadel master key — **exactly 32 characters** |
| `APISIX_ADMIN_KEY` | APISIX admin API key (any strong value) |

Generate the random values with `openssl rand -hex 16` (32 hex chars, no special characters).

> **Do not rotate `ZITADEL_DB_PASSWORD` or `ZITADEL_MASTERKEY` after the first successful deploy** —
> Postgres persists data with that password and Zitadel encrypts its database with that master key.
>
> `DIGITALOCEAN_ACCESS_TOKEN` and `DOKS_CLUSTER_ID` from the earlier approach are unused now and may
> be deleted.

---

## 7. How to deploy / re-deploy

CD is **manual-trigger** (a gateway should not redeploy on every push):

1. **Actions → CD → Run workflow**, set the `confirm` input to `deploy`.

The pipeline:
1. Installs `kubectl` + `helm`, writes the kubeconfig from `DOKS_KUBECONFIG`.
2. Applies `k8s/namespaces.yaml`.
3. Creates `zitadel-db`, `zitadel-masterkey`, `apisix-admin-key` Secrets from GitHub Secrets.
4. Applies `helm/zitadel/postgres.yaml` and waits for Postgres.
5. Runs `helm/deploy.sh` (installs Zitadel, then APISIX + ingress controller, then `kubectl apply -f routes/`).
6. Prints services (LoadBalancer IP), ApisixRoutes, and pods.

The pipeline is idempotent — re-running it upgrades in place.

---

## 8. Operating the cluster (Git Bash / CMD / PowerShell)

Point `kubectl` at the kubeconfig, then inspect:

```bash
# Git Bash
export KUBECONFIG="/c/Users/<you>/Downloads/<cluster>-kubeconfig.yaml"
kubectl get pods -n sfg-gateway          # gateway pods (apisix, zitadel, postgres)
kubectl get svc  -n sfg-gateway          # APISIX LoadBalancer EXTERNAL-IP
kubectl get apisixroutes -A              # routes across all namespaces
kubectl logs -l job-name=sfg-zitadel-init -n sfg-gateway   # init job logs
```

```powershell
# PowerShell
$env:KUBECONFIG="C:\Users\<you>\Downloads\<cluster>-kubeconfig.yaml"
kubectl get pods -n sfg-gateway
```

---

## 9. Current state & remaining work

**Deployed and Running:** Postgres, Zitadel (init + setup jobs Completed), Zitadel login, APISIX,
etcd, APISIX ingress controller. All 15 `ApisixRoute` objects applied across `sfg-gateway`,
`sfg-apps`, `sfg-labs`.

**Remaining:**
- **LoadBalancer IP** — confirm `sfg-apisix-gateway` `EXTERNAL-IP` once DigitalOcean provisions it.
- **DNS** — point `auth.sfg-labs.in`, `api.nma-india.in`, `api.baithak.live`, `api.cms.sfg-labs.in`,
  `api.suwalka-pos.sfg-labs.in` at the LoadBalancer IP.
- **TLS** — terminate at the DO LoadBalancer or Cloudflare, or add cert-manager (Zitadel is
  configured with `ExternalSecure: true` / port 443).
- **Backend services** — NMA/Baithak/CMS (`sfg-apps`) and Suwalka (`sfg-labs`) pods are deployed
  from their own repos. Until then, protected routes return 502/503 and only the Zitadel auth route
  is live.
- **Housekeeping** — remove unused `DIGITALOCEAN_ACCESS_TOKEN` / `DOKS_CLUSTER_ID` secrets; the CD
  actions emit a Node 20 deprecation warning (bump `actions/checkout`, `azure/setup-*` when convenient).
