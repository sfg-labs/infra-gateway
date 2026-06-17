# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`infra-gateway` is the **centralised API gateway + identity provider for all sfg-labs services** — built on **Apache APISIX** (gateway) + **Zitadel** (OIDC IdP). It fronts every backend in the sfg-labs estate: the Suwalka Motors POS/DMS services (`suwalka-*`), NMA India, Baithak, and CMS.

> **Deployment target: DigitalOcean Kubernetes (DOKS, region `sgp1`), via the GitHub Actions CD pipeline** (`.github/workflows/cd.yaml`). The original design targeted self-managed **k3s** (Cantech Mumbai DC) — the `k3s/` provisioning scripts and some doc/comment references to "the master IP" / NodePort `:30080` are from that era and are **retained but not the live path**. `docs/doks-deployment.md` is the authoritative record of the migration and the current cluster reality — read it before touching deploy/Helm/route-namespace concerns.

This repo is **infrastructure-as-config, not an application** — there is no compiled code, no `package.json`, no build step. It contains declarative **APISIX route CRDs** (`routes/*.yaml`), **Helm values** (`helm/`), **k8s namespace manifests** (`k8s/namespaces.yaml`), **k3s provisioning scripts** (`k3s/`, legacy), a **local Docker test stack** (`docker-compose.yml` + `docker/`), and **bash test/lint scripts** (`tests/`). All work is editing YAML and shell, then validating it.

> The workspace-level `H:\Personal\SFG\CLAUDE.md` maps the ten Suwalka *backend/app* repos but does **not** list this repo. This is the gateway that sits in front of those services. The auth model documented there (APISIX validates the OIDC JWT and injects `X-Userinfo`; the `readUser` middleware decodes it; services do zero in-process auth) — **this repo is the APISIX half that produces those headers.**

## The core mental model

```
Client ──HTTPS──▶ APISIX (openid-connect plugin: verify JWT via Zitadel JWKS)
                    │  invalid/missing token → 401, backend never contacted
                    └─valid─▶ inject X-Userinfo + X-User-* headers ─▶ backend pod
```

- **Auth happens here, once, at the edge.** A route gets auth by including the `openid-connect` plugin in `bearer_only: true` mode. Omitting that plugin = the route is **public** (anyone on the internet, no token). This is why `routes/public.yaml` carries a loud warning — adding a path there bypasses all auth.
- **The gateway trusts Zitadel; backends trust the gateway.** Discovery is always `https://auth.sfg-labs.in/.well-known/openid-configuration`, alg `RS256`, and the userinfo blob is forwarded as the `X-Userinfo` header (`userinfo_header_name: X-Userinfo`) — the exact header the backend `readUser` middleware expects.

## Two route definitions that must stay in sync

There are **two parallel, independent declarations of the same routing intent** — editing one does not change the other:

| | Production | Local Docker |
|---|---|---|
| Source | `routes/*.yaml` (`ApisixRoute` CRDs) | `docker/apisix/setup-routes.sh` (Admin API calls) |
| Applied by | APISIX Ingress Controller watching CRDs | curl `PUT` to Admin API `:9180` |
| Hosts | real, e.g. `api.suwalka-pos.sfg-labs.in` | `*.localhost`, e.g. `api.suwalka.localhost` |
| Backends | real K8s Services | `mock-backend` (httpbin) stands in for every pod |
| Auth server | `auth.sfg-labs.in` | `zitadel:8080` container |

When you add or change a production route in `routes/`, mirror it into `setup-routes.sh` if you want the local smoke tests to exercise it. They will not auto-sync.

## Namespaces (easy to get wrong — changed in the DOKS migration)

**The installed `ApisixRoute` CRD (`apisix.apache.org/v2`) routes only to Services in the route's OWN namespace — there is NO `backends[].serviceNamespace` field** (strict decoding rejects it; this is fix 5.3 in `docs/doks-deployment.md`). So **each route now lives co-located in its backend's namespace**, not all in `sfg-gateway`:

- **Zitadel / gateway-internal routes → `sfg-gateway`** (where APISIX + the ingress controller + Zitadel + its Postgres live).
- **NMA / Baithak / CMS → `sfg-apps`.**
- **Suwalka services → `sfg-labs`** — see the namespace note atop `routes/suwalka-org-hr-payroll.yaml`. Do **not** move Suwalka backends to `sfg-apps`.
- `routes/public.yaml` is therefore **split into three `ApisixRoute` objects** — `public-routes-gateway` (sfg-gateway), `public-routes-apps` (sfg-apps), `public-routes-suwalka` (sfg-labs).
- The three namespaces are declared in `k8s/namespaces.yaml` (applied idempotently before any Helm release / route).
- **Watch config:** `helm/apisix/values.yaml` `ingress-controller.config.kubernetes.watchNamespaces` now lists all three (`sfg-gateway`, `sfg-apps`, `sfg-labs`) — the earlier `sfg-labs`-missing mismatch is **resolved**. If a route doesn't take effect, confirm it's in its backend's namespace AND that namespace is watched.

## Anatomy of a route file

Every `routes/<service>.yaml` is one `ApisixRoute` with this shape (copy `routes/nma-engine.yaml` or `routes/suwalka-sales.yaml` as a template):

- `metadata`: `name` (unique across all files), `namespace` = **the backend's namespace** (`sfg-labs` for Suwalka, `sfg-apps` for NMA/Baithak/CMS, `sfg-gateway` for Zitadel — see Namespaces above), `labels` (`sfg-project`, `sfg-auth: jwt|public`), `annotations` (`sfg-labs.in/description|team|upstream`).
- `spec.http[]`: each rule has a **unique `name` across the whole repo** (the duplicate-name check in `validate-routes.sh` enforces this), `match.hosts` + `match.paths` + `match.methods`, `backends` (`serviceName`/`servicePort`/`weight` — **no `serviceNamespace`**; the route must already be in the backend's namespace), and `plugins`.
- Standard plugin stack for a protected route: `openid-connect` (auth) → `request-id` (`X-Request-Id`, echoed in response) → `limit-req` (rate limit, `rejected_code: 429`) → `response-rewrite` (sets `X-Gateway: sfg-labs`, `X-Project: <name>`).
- Public/health endpoints go in `routes/public.yaml` with the `openid-connect` plugin **omitted**. Health paths are listed explicitly (no wildcard); note Suwalka uses `/healthz` while NMA/Baithak/CMS use `/health`.

## Commands

This machine's host shell is **PowerShell**, but every script here is **bash** — run them through the Bash tool (`bash tests/...`), not PowerShell. They assume a POSIX environment with `python3`, `yamllint`, `shellcheck`, `helm`, `kubectl`, `docker`.

```bash
# Validate / lint (no cluster, no Docker needed) — run these before every PR
bash tests/validate-routes.sh    # ApisixRoute schema + duplicate rule-name check (python3 + pyyaml)
bash tests/lint.sh               # yamllint (relaxed, line-length 200) + shellcheck
bash tests/helm-template.sh      # helm template dry-run of APISIX + Zitadel charts

# Local Docker stack (full request path, no k3s)
docker compose up -d                       # etcd, apisix(:9080/:9180), zitadel(:8080), postgres, mock-backend(:8081)
bash docker/apisix/setup-routes.sh         # configure routes via Admin API (wait for APISIX healthy first)
bash tests/smoke/smoke-test-local.sh       # asserts 200 on health, 401 on protected w/o token, OIDC discovery

# Live smoke test against a deployed environment
bash tests/smoke/smoke-test.sh https://api.nma-india.in

# Deploy to DOKS (the live path) — normally via CD, not locally:
#   GitHub → Actions → "CD" → Run workflow → type "deploy" in the confirm input.
# The pipeline writes kubeconfig from the DOKS_KUBECONFIG secret, applies namespaces,
# materializes k8s Secrets from GitHub Secrets, deploys Postgres, then runs helm/deploy.sh.
# To run the deploy by hand with kubeconfig already configured:
bash helm/deploy.sh [--dry-run]            # Zitadel → APISIX+ingress-controller → kubectl apply -f routes/

# Live smoke test against the deployed gateway
bash tests/smoke/smoke-test.sh https://api.nma-india.in

# Legacy k3s provisioning (NOT the live path — see docs/doks-deployment.md)
bash k3s/install-master.sh
bash k3s/install-worker.sh <MASTER_IP> <NODE_TOKEN>
```

- **CI** (`.github/workflows/ci.yml`, **self-hosted runners**) runs four jobs on push/PR to `main`: `lint`, `validate-routes`, `helm-template`, and `integration` (spins up the full `docker compose` stack, runs `setup-routes.sh`, then `smoke-test-local.sh`). Match these locally before pushing.
- **CD** (`.github/workflows/cd.yaml`, GitHub-hosted `ubuntu-latest`) is **manual-trigger only** (`workflow_dispatch`, requires the `confirm` input = `deploy`) — a gateway should not redeploy on every push. It deploys to DOKS and is idempotent (re-running upgrades in place). Required GitHub Secrets: `DOKS_KUBECONFIG`, `ZITADEL_DB_PASSWORD`, `ZITADEL_MASTERKEY` (**exactly 32 chars**), `APISIX_ADMIN_KEY`. Full detail in `docs/doks-deployment.md`.

## Conventions & gotchas

- **The local dev APISIX admin key (`edd1c9f034335f136f87ad84b625c8f1`) is hardcoded for Docker only.** In production it is injected from a Kubernetes Secret (`apisix-admin-key`), `allow_admin` is restricted to the pod CIDR (not `0.0.0.0/0`), and the Admin API is not NodePort-exposed. `docker/apisix/config.yaml` documents each production difference inline — never carry the dev posture to a reachable host.
- **`docker/apisix/config.yaml` configures the *local* APISIX only.** Production APISIX is configured entirely by the Helm chart + the watched CRDs.
- **Adding a service** is documented end-to-end in `docs/adding-a-service.md`: register a K8s Service (correct namespace), add `routes/<service>.yaml`, validate locally, open a PR (`route/<service>` branch). The ingress controller picks up merged CRDs automatically — no redeploy. **Caveat:** `docs/adding-a-service.md` and `README.md` route examples still show `backends[].serviceNamespace` — that field is no longer valid (see Namespaces). Put the route in the backend's namespace and drop `serviceNamespace`.
- **Rate-limit conventions** (req/s, burst) per service tier are tabled in `docs/adding-a-service.md`; deviate only with a reason in the PR.
- Routes currently defined: `nma-engine`, `baithak`, `cms`, `public`, and the Suwalka set (`customer-vehicle`, `incentive`, `inventory-pricing`, `notification`, `org-hr-payroll`, `platform`, `sales`, `tasks`, `workshop`).
- Commit style follows Conventional Commits scoped to this repo (`feat(routes):`, `ci:`, `security:`, `fix(smoke):` — see `git log`).
