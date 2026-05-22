# Adding a New Service to the Gateway

This guide is for **backend service owners** who need their service routed through the sfg-labs API gateway.

---

## Overview

All external API traffic flows through APISIX. Your service pod never sees a request unless the JWT has been validated. You only need to:

1. Ensure your K8s `Service` resource exists in `sfg-apps` namespace
2. Create an `ApisixRoute` file in this repo (`routes/your-service.yaml`)
3. Open a PR — gateway picks up the route automatically on merge

---

## Step 1 — Register your K8s Service

In your service's own repo, make sure a K8s `Service` resource exists:

```yaml
# In your-service-repo/k8s/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: your-service-name      # ← this name is referenced in the ApisixRoute
  namespace: sfg-apps          # must be sfg-apps
spec:
  selector:
    app: your-service-name
  ports:
    - port: 3000               # the port your container listens on
      targetPort: 3000
```

Apply it: `kubectl apply -f k8s/service.yaml`

Verify: `kubectl -n sfg-apps get svc your-service-name`

---

## Step 2 — Create an ApisixRoute

Copy `routes/nma-engine.yaml` as a starting point and update:

```yaml
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: your-service-name          # unique across all routes
  namespace: sfg-gateway
  labels:
    sfg-project: your-project
    sfg-auth: jwt
  annotations:
    sfg-labs.in/description: "Short description of what this service does"
    sfg-labs.in/team: "your-team-name"
    sfg-labs.in/upstream: "your-service-name:3000"
spec:
  http:
  - name: your-service-api         # unique within this file
    match:
      hosts:
      - api.your-domain.com        # your service's external hostname
      paths:
      - /api/*                     # which paths to forward
      methods:
      - GET
      - POST
      - PUT
      - PATCH
      - DELETE
    backends:
    - serviceName: your-service-name    # must match K8s Service name in sfg-apps
      serviceNamespace: sfg-apps
      servicePort: 3000
      weight: 100
    plugins:
    - name: openid-connect
      enable: true
      config:
        discovery: https://auth.sfg-labs.in/.well-known/openid-configuration
        bearer_only: true
        realm: your-realm            # get this from the platform team
        set_userinfo_header: true
        userinfo_header_name: X-Userinfo
        token_signing_alg_values_expected: RS256
        timeout: 3
    - name: request-id
      enable: true
      config:
        header_name: X-Request-Id
        include_in_response: true
    - name: limit-req
      enable: true
      config:
        rate: 100                    # requests per second
        burst: 50
        rejected_code: 429
        key_type: var
        key: consumer_name
```

---

## Step 3 — Validate your route file locally

Before opening a PR, run:

```bash
# From repo root
bash tests/validate-routes.sh
bash tests/lint.sh
```

Both must pass with 0 failures.

---

## Step 4 — Open a PR

- Branch name: `route/your-service-name`
- PR title: `feat(routes): add your-service-name gateway route`
- Reviewers: `@platform-team`

The ingress controller picks up approved CRDs automatically — no manual apply needed after merge.

---

## Headers your service receives

After the gateway validates the JWT, these headers are injected:

| Header | Example | Description |
|--------|---------|-------------|
| `X-User-Id` | `usr_2abc123` | Zitadel internal user ID |
| `X-User-Email` | `user@example.com` | Authenticated user's email |
| `X-User-Roles` | `admin,auditor` | Comma-separated roles from Zitadel |
| `X-Tenant-Id` | `tenant_xyz` | Multi-tenant identifier |
| `X-Userinfo` | `eyJ...` | Base64-encoded full OIDC userinfo JSON |
| `X-Request-Id` | `req_abc123` | Unique request trace ID |
| `X-Gateway` | `sfg-labs` | Confirms request came through gateway |

**Trust these headers completely.** APISIX has already validated the JWT before injecting them.

---

## Adding public (unauthenticated) routes

If your service has endpoints that must be public (health checks, webhooks), add them to `routes/public.yaml`:

```yaml
- name: your-service-health
  match:
    hosts:
    - api.your-domain.com
    paths:
    - /health
    - /webhooks/*
  backends:
  - serviceName: your-service-name
    serviceNamespace: sfg-apps
    servicePort: 3000
    weight: 100
  # No openid-connect plugin = no auth = public
```

> **Warning:** Any path in `public.yaml` is reachable by anyone on the internet without a token. Only add paths that genuinely need to be public.

---

## Rate limits

Default limits per service:

| Service type | Requests/sec | Burst |
|---|---|---|
| Standard API | 100 | 50 |
| High-volume (events, analytics) | 500 | 200 |
| Low-volume (admin, config) | 30 | 15 |
| Webhooks (public) | 20 | 10 |

If your service needs different limits, specify in your `ApisixRoute` under the `limit-req` plugin and note the reason in the PR description.

---

## Troubleshooting

**Getting 401 on all requests:**
- Check the `Authorization: Bearer <token>` header is present
- Verify the token is from Zitadel (not another IdP)
- Confirm the `realm` in your route matches your Zitadel application's realm

**Getting 404 (route not found):**
- Check the `hosts` in your ApisixRoute matches the exact `Host` header the client sends
- Verify the route was applied: `kubectl -n sfg-gateway get apisixroutes`

**Service pod not receiving requests:**
- Check the `serviceName` in your route matches the K8s Service name exactly
- Verify the Service is in namespace `sfg-apps`: `kubectl -n sfg-apps get svc`
- Check pod logs: `kubectl -n sfg-apps logs deploy/your-service-name`

**High latency on first request:**
- APISIX caches Zitadel's JWKS keys. The first request after a cache miss may be slightly slower. This is normal and resolves on subsequent requests.
