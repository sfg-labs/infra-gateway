# Zitadel Complement Token Action — suwalka claims

Mints `suwalka_admin` / `suwalka_caps` / `suwalka_identity` / `suwalka_outlet_set` /
`suwalka_dept_set` custom claims into the token Zitadel issues, so they reach
every backend service via APISIX's `X-Userinfo` header. Without this Action,
`req.user.caps` (and `.adminGrants`, `.employeeId`, etc.) is always empty for
every user, and any endpoint gated by `resolveModuleScopeFilter` (e.g.
org-hr-payroll's payroll, sales, hrms capability checks) 403s unconditionally —
independent of what's actually granted in the `designation_capabilities` /
`admin_grants` DB tables.

This is **not** a Kubernetes resource and is **not applied by CI/CD** — Zitadel
Actions live in Zitadel's own database, configured through its Console UI (or
Management API, which this workspace has no credentials for). This directory
exists purely so the Action source is version-controlled and reviewable; you
must paste it into the Console by hand.

## Steps (Zitadel Console)

1. Go to `https://sfg-labs.faithandgamble.in/ui/console`.
2. **Actions → Actions tab → New**. Paste in the contents of
   `complementTokenClaims.js`. Before saving, replace
   `<set-me-in-the-zitadel-console-only>` with the real `INTERNAL_GRANT_TOKEN`
   secret value:
   ```
   kubectl -n sfg-labs get secret suwalka-auth-secrets -o jsonpath='{.data.internal-grant-token}' | base64 -d
   ```
   (requires `KUBECONFIG=H:\Personal\SFG\k8s-1-35-5-do-1-sgp1-1781614721042-kubeconfig.yaml`).
   **Do not commit that real value into this file or anywhere in git** — it's a
   shared secret with `suwalka-auth`.
3. Set the **Timeout** to something comfortable (the endpoint is a single
   in-cluster DB read; 5s is generous).
4. **Actions → Flows → Complement Token flow → "Pre Userinfo creation"
   trigger → add the Action you just created.**
5. Save. No redeploy needed — it takes effect on the next token issuance
   (next login; existing access tokens are unaffected until they're refreshed
   or a new login happens).

## Verifying it worked

Log in again in the browser, then decode the new access/id token (or check
the `X-Userinfo` value APISIX forwards) and confirm `suwalka_caps` /
`suwalka_admin` are present. Practically: reload `/payroll` in admin-web — the
403 should be gone (assuming the calling designation actually has a
`designation_capabilities` row for the `payroll` module, e.g. the row already
inserted for the GM designation `da000000-0000-0000-0000-0000000000f1`).

## Why fail-open

The Action must never block login: an unmapped user (no employee row, network
hiccup, non-200 response) simply results in the claim staying absent, which
every backend controller already treats as "no capability" — the
authorization side is fail-closed, so the login side can safely fail-open.

## `setIdentityClaims` — per-environment resolver (2026-09-19)

`setIdentityClaims.js` is the Action that fetches the claims live from org-hr's
`/api/hr/internal/admin-grants/by-sub`. Dev and UAT share this Zitadel, so it
chooses the org-hr by the **client id the token is issued for**
(`ctx.v1.application.getClientId()`, available on *Pre Userinfo creation*):

| Client id | Source | Resolver | Token line |
|---|---|---|---|
| `389855554874442152` | `oidc-client-id` in `sfg-pos-app-uat/suwalka-auth-secrets` | `suwalka-org-hr-payroll.sfg-pos-app-uat.svc.cluster.local:3001` | `INTERNAL_TOKEN_UAT` |
| anything else (dev `378146155789287497`, console, unknown) | — | `suwalka-org-hr-payroll.sfg-pos-app.svc.cluster.local:3001` | `INTERNAL_TOKEN_DEV` |

Before this, every UAT login carried **dev's** `suwalka_admin` / `suwalka_caps` /
`suwalka_identity`, so a dev super-admin looked like a super-admin on UAT while UAT's
own `admin_grants` disagreed (manual attendance: *"Record is outside your outlet
scope"*, 2026-09-19).

The two namespaces have **different** `internal-grant-token` values — fill each line
from its own namespace:

```
kubectl -n sfg-pos-app     get secret suwalka-auth-secrets -o jsonpath='{.data.internal-grant-token}' | base64 -d
kubectl -n sfg-pos-app-uat get secret suwalka-auth-secrets -o jsonpath='{.data.internal-grant-token}' | base64 -d
```

A new environment needs its own row in `RESOLVERS`. Adding a client id to the
`suwalka-auth` secret without that row silently sends its logins to dev.
