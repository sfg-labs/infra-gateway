# infra-gateway

> **One gateway. Multiple projects.**  
> Centralised API Gateway and Identity Provider for all sfg-labs services.

[![k3s](https://img.shields.io/badge/k3s-v1.30-blue)](https://k3s.io)
[![APISIX](https://img.shields.io/badge/APISIX-3.x-orange)](https://apisix.apache.org)
[![Zitadel](https://img.shields.io/badge/Zitadel-latest-green)](https://zitadel.com)
[![CI](https://github.com/sfg-labs/infra-gateway/actions/workflows/ci.yml/badge.svg)](https://github.com/sfg-labs/infra-gateway/actions/workflows/ci.yml)

Built on **Apache APISIX** + **Zitadel**, deployed on **k3s** on Cantech Mumbai DC.  
Every API call for **NMA India**, **Baithak**, and **CMS** flows through this gateway.  
Services receive validated user context as HTTP headers — zero auth code needed.

**GitHub:** [sfg-labs/infra-gateway](https://github.com/sfg-labs/infra-gateway)

---

## Network Flow

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                         PRODUCTION NETWORK FLOW                             ║
╚══════════════════════════════════════════════════════════════════════════════╝

  📱 Mobile App / 🌐 Web Browser
       │
       │  ① HTTPS :443  (TLS 1.3 — all bytes encrypted)
       │
       ▼
  ┌─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
  │  Cloudflare  (recommended, optional)  │  DDoS shield + free TLS cert
  │  DNS: api.nma-india.in → 103.x.x.x   │
  └─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┬─ ─ ─ ─ ─┘
       │  (without Cloudflare, TLS terminates at APISIX using Let's Encrypt)
       │
       │  ② HTTP/S  →  port 30080 on k3s-master  (NodePort)
       │
       ▼
╔══════════════════════════════════════════════════════════════════════════════╗
║  k3s CLUSTER — Cantech Mumbai DC                                            ║
║  ─────────────────────────────────────────────────────────────────────────  ║
║                                                                              ║
║   k3s-master  (103.x.x.x)       worker-01  (10.0.0.2)   worker-02 (10.0.0.3)║
║   ┌──────────────────────┐      ┌──────────────────┐    ┌──────────────────┐║
║   │  NodePort :30080     │      │  APISIX Pod      │    │  APISIX Pod      │║
║   │  (entry point)  ─ ─ ─③─ ─ ▶│  :9080           │    │  :9080           │║
║   │                      │      │                  │    │                  │║
║   │  k3s control plane   │      │  ┌────────────┐  │    │  ┌────────────┐  │║
║   │  (schedules pods)    │      │  │ ④ JWT check │  │    │  │ ④ JWT check│  │║
║   └──────────────────────┘      │  │  NO  → 401  │  │    │  │  NO  → 401 │  │║
║                                  │  │  YES → fwd  │  │    │  │  YES → fwd │  │║
║   ┌──────────────────────┐      │  └──────┬─────┘  │    │  └──────┬─────┘  │║
║   │  Zitadel :8080       │◀─────│    JWKS │cache   │    │    JWKS │cache   │║
║   │  (auth server)       │      │         │         │    │         │         │║
║   │  - issues JWT tokens │      └──────────┼────────┘    └──────────┼────────┘║
║   │  - serves /auth/*    │                 │                         │        ║
║   │  - JWKS public keys  │                 │  ⑤ WireGuard encrypted  │        ║
║   └──────────────────────┘                 │    (inter-node traffic) │        ║
║                                             │                         │        ║
║   ┌──────────────────────┐      ┌──────────▼────────┐  ┌─────────────▼──────┐║
║   │  etcd :2379          │      │  NMA Engine :3000  │  │  Baithak API :8000 │║
║   │  (gateway config)    │      │  (sfg-apps ns)     │  │  CMS API     :8001 │║
║   └──────────────────────┘      │                    │  │  (sfg-apps ns)     │║
║                                  │  ⑥ Reads headers:  │  │                    │║
║   ┌──────────────────────┐      │  X-User-Id         │  │  X-User-Id         │║
║   │  Postgres :5432      │◀─────│  X-User-Email      │  │  X-User-Email      │║
║   │  db-01 (outside K8s) │      │  X-Tenant-Id       │  │  X-Tenant-Id       │║
║   └──────────────────────┘      │  X-User-Roles      │  │  X-User-Roles      │║
║                                  └───────────────────┘  └────────────────────┘║
╚══════════════════════════════════════════════════════════════════════════════╝
       │
       │  ⑦ Response travels back the same path
       │
       ▼
  📱 Mobile App / 🌐 Web Browser  ← receives response
```

**Step by step:**

| Step | What happens | Where |
|------|-------------|-------|
| ① | Client sends HTTPS request with `Authorization: Bearer <token>` | Internet |
| ② | Hits k3s-master on port 30080 (NodePort exposed to internet) | Cantech DC |
| ③ | k3s load-balances to any APISIX pod (worker-01 or worker-02) | Inside cluster |
| ④ | APISIX checks JWT — invalid/missing = **401 returned, pod never contacted** | APISIX pod |
| ⑤ | Valid request forwarded to service pod over WireGuard encrypted link | Cross-node |
| ⑥ | Service reads pre-validated user headers — no token logic needed | Service pod |
| ⑦ | Response returns to client | Everywhere |

---

## Auth Flow

```
╔══════════════════════════════════════════════════════════════════╗
║                    HOW LOGIN WORKS                               ║
╚══════════════════════════════════════════════════════════════════╝

  App                    APISIX                 Zitadel
   │                       │                       │
   │── POST /auth/login ──▶│── (public route) ────▶│
   │   {email, password}   │   no JWT check        │── verifies credentials
   │                       │                       │── generates JWT (RS256)
   │◀─ {access_token,  ────│◀──────────────────────│
   │    refresh_token,     │                        │
   │    expires_in: 3600}  │                        │
   │                       │                        │
   │  stores token locally │                        │


╔══════════════════════════════════════════════════════════════════╗
║                 HOW EVERY API CALL WORKS                         ║
╚══════════════════════════════════════════════════════════════════╝

  App                    APISIX                 Your Service Pod
   │                       │                       │
   │── GET /api/audit ────▶│                       │
   │   Authorization:      │                       │
   │   Bearer eyJ...       │                       │
   │                       │── verify JWT ─────┐   │
   │                       │   (local JWKS,    │   │
   │                       │    no network)    │   │
   │                       │                   │   │
   │                       │  ┌─ INVALID ──────┘   │
   │◀── 401 Unauthorized ──│◀─┘  (pod never sees)  │
   │                       │                       │
   │                       │  ┌─ VALID ────────────┘
   │                       │──▶ forward + inject:  │
   │                       │   X-User-Id           │
   │                       │   X-User-Email        │
   │                       │   X-Tenant-Id         │
   │                       │   X-User-Roles        │
   │                       │                       │── handles request
   │◀────── 200 OK ────────│◀──────────────────────│   (no JWT code needed)
```

---

## Local Docker Test Flow

```
╔══════════════════════════════════════════════════════════════════╗
║                LOCAL DOCKER TESTING (no k3s needed)             ║
╚══════════════════════════════════════════════════════════════════╝

  Your laptop
  │
  ├── curl localhost:9080   ──▶  APISIX container :9080
  │                                      │
  ├── curl localhost:8080   ──▶  Zitadel container :8080
  │                                      │
  └── curl localhost:8081   ──▶  mock-backend (httpbin) :80
                                         │ (stands in for NMA/Baithak/CMS pods)

  docker compose services:
  ┌─────────────────┬────────────┬───────────────────────────────┐
  │ Service         │ Port       │ Purpose                       │
  ├─────────────────┼────────────┼───────────────────────────────┤
  │ etcd            │ 2379       │ APISIX config store           │
  │ apisix          │ 9080       │ Gateway (send API calls here) │
  │ apisix-admin    │ 9180       │ Admin API (configure routes)  │
  │ zitadel         │ 8080       │ Auth server (login + OIDC)    │
  │ postgres        │ 5432       │ Zitadel state                 │
  │ mock-backend    │ 8081       │ Fake NMA/Baithak/CMS pod      │
  └─────────────────┴────────────┴───────────────────────────────┘
```

---

## Security Layers

```
╔══════════════════════════════════════════════════════════════════╗
║                    WHAT PROTECTS YOUR DATA                       ║
╚══════════════════════════════════════════════════════════════════╝

  LAYER 1 — Internet traffic
  ──────────────────────────
  Client ══[TLS 1.3]══▶ Cloudflare / APISIX

  Everything on the wire is encrypted.
  Nobody can read or modify bytes in transit.

  LAYER 2 — Inside the cluster (node to node)
  ────────────────────────────────────────────
  worker-01 ══[WireGuard kernel encryption]══▶ worker-02

  Enabled via --flannel-backend=wireguard-native on k3s install.
  Even if someone physically taps the server's network cable,
  they see only encrypted WireGuard packets.

  LAYER 3 — Token integrity
  ─────────────────────────
  JWT signed by Zitadel with RS256 private key.
  APISIX verifies with public key only.
  Tamper with any byte in the token → signature fails → 401.
  Private key never leaves Zitadel.

  ┌──────────────────┬─────────────────────┬────────────────────┐
  │ Attack           │ Blocked by          │ Result             │
  ├──────────────────┼─────────────────────┼────────────────────┤
  │ Sniff internet   │ TLS 1.3             │ Encrypted garbage  │
  │ Sniff inter-node │ WireGuard           │ Encrypted garbage  │
  │ Forge JWT        │ RS256 signature     │ 401                │
  │ Tamper JWT body  │ RS256 signature     │ 401                │
  │ No token at all  │ APISIX auth check   │ 401 (pod safe)     │
  │ Expired token    │ JWT exp claim check │ 401                │
  └──────────────────┴─────────────────────┴────────────────────┘
```

---

## Services Routed

| Project | External Host | Pod | Port | Auth |
|---------|---------------|-----|------|------|
| NMA India | `api.nma-india.in` | `nma-india-engine` | 3000 | JWT |
| Baithak | `api.baithak.live` | `baithak-api` | 8000 | JWT |
| CMS | `api.cms.sfg-labs.in` | `cms-api` | 8001 | JWT |
| Auth | `auth.sfg-labs.in` | `zitadel` | 8080 | Public |

---

## How to connect your service (BE team)

**Step 1** — Your K8s Service must be in `sfg-apps` namespace:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service        # ← remember this name
  namespace: sfg-apps
spec:
  selector:
    app: my-service
  ports:
    - port: 3000
```

**Step 2** — Create `routes/my-service.yaml` in this repo:
```yaml
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: my-service
  namespace: sfg-gateway
spec:
  http:
  - name: my-service-api
    match:
      hosts:
      - api.my-domain.com
      paths:
      - /api/*
    backends:
    - serviceName: my-service
      serviceNamespace: sfg-apps
      servicePort: 3000
    plugins:
    - name: openid-connect
      enable: true
      config:
        discovery: https://auth.sfg-labs.in/.well-known/openid-configuration
        bearer_only: true
        set_userinfo_header: true
        userinfo_header_name: X-Userinfo
```

**Step 3** — Open a PR. Gateway picks it up on merge, no restart needed.

**Headers your service receives (pre-validated):**
```
X-User-Id      →  usr_abc123
X-User-Email   →  user@example.com
X-User-Roles   →  admin,auditor
X-Tenant-Id    →  tenant_xyz
X-Request-Id   →  req_abc123
X-Gateway      →  sfg-labs
```

See [docs/adding-a-service.md](docs/adding-a-service.md) for the full guide.

---

## Quick Start

```bash
# 1. Provision k3s (run on each VM)
bash k3s/install-master.sh
bash k3s/install-worker.sh <MASTER_IP> <NODE_TOKEN>
bash k3s/kubeconfig.sh <MASTER_PUBLIC_IP>

# 2. Deploy gateway + auth
bash helm/deploy.sh
kubectl apply -f routes/

# 3. Test locally with Docker first
docker compose up -d
bash docker/apisix/setup-routes.sh
bash tests/smoke/smoke-test-local.sh
```

## Running Tests

```bash
bash tests/validate-routes.sh        # route YAML schema
bash tests/lint.sh                   # yamllint + shellcheck
bash tests/helm-template.sh          # Helm dry-run
bash tests/smoke/smoke-test-local.sh # Docker stack smoke tests
bash tests/smoke/smoke-test.sh https://api.nma-india.in  # live
```

## Infrastructure Cost

| VM | Spec | Role | ₹/mo |
|----|------|------|------|
| k3s-master | 4c / 8 GB | Control plane | 1,500 |
| worker-01 | 4c / 8 GB | APISIX + Zitadel + NMA | 1,500 |
| worker-02 | 4c / 8 GB | APISIX + Baithak + CMS | 1,500 |
| db-01 | 4c / 16 GB | Postgres (outside K8s) | 2,800 |
| ops-01 | 2c / 4 GB | Grafana + Prometheus | 800 |
| **Total** | | **Gateway = pods, ₹0 extra** | **₹8,100** |

---

## Created By

**Faith & Gamble IT** · Ashish Sharma  
[sfg-labs](https://github.com/sfg-labs) · Mumbai, India · 2026

> *One gateway. Multiple projects.*
