# UAT's own Zitadel instance

**Since 2026-09-19** UAT (`sfg-pos-app-uat`) authenticates against its **own Zitadel virtual
instance**, `https://sfg-labs-uat.faithandgamble.in`. It runs on the same `sfg-zitadel`
deployment as the dev/shared instance (`https://sfg-labs.faithandgamble.in`); Zitadel picks
the instance from the request's Host header.

## Why

One instance with one org served dev **and** UAT, and login names are unique across the whole
instance. Both environments hold the same staff with the same email, and the email is the login
name. So suwalka-auth provisioning on UAT found and **linked dev's logins** (and orphans a UAT
data wipe left behind): UAT employees signed in to dev accounts, and a UAT password reset rotated
dev's password. suwalka-auth #35 now refuses such links; this instance removes the collision.

## What lives where

| Piece | Where |
|---|---|
| DNS | GoDaddy A `sfg-labs-uat` → APISIX LB |
| TLS | `k8s/zitadel-uat-tls.yaml` (cert-manager `letsencrypt-prod`, HTTP-01) |
| Route to Zitadel | `routes/zitadel-uat-instance.yaml` (`sfg-gateway`, → `sfg-zitadel:8080`) |
| Token validation on UAT APIs | every `routes/*-uat.yaml` → `openid-connect.discovery` = the UAT instance |
| System API user that created the instance | `suwalka-uat-sysadmin` (SYSTEM_OWNER) in `sfg-zitadel-config-yaml` → `SystemAPIUsers`. Public key only; the private key is held by the operator, never in git |
| UAT auth config | `sfg-pos-app-uat/suwalka-auth-secrets`: `zitadel-issuer`, `oidc-client-id`, `mgmt-pat`, `service-account-token`, `events-pat` point at the UAT instance |

**Not in Helm.** `SystemAPIUsers` was added to the live config map (Helm values for `sfg-zitadel`
are not in git, and the login deployment carries hand edits). A `helm upgrade` of `sfg-zitadel`
would drop `suwalka-uat-sysadmin`. Nothing needs it day to day — it was only used to create the
instance — but do not `helm upgrade` Zitadel without carrying the live config forward.

## What the instance contains

Mirrors what UAT used on the shared instance (values read live at migration time):

- **Org** `Suwalka UAT`, org lockout policy **5** password attempts; default login and
  password-complexity policies (same as the shared instance).
- **Project + OIDC app** `Suwalka-UAT`: web, authorization-code + refresh, auth method none, JWT
  access tokens, role + userinfo assertions, redirect `https://suwalka-uat.faithandgamble.in/auth/callback`.
- **Service users:** `suwalka-auth-uat-mgmt` (ORG_USER_MANAGER), `suwalka-auth-uat-login`
  (IAM_LOGIN_CLIENT), `svc-suwalka-events-uat` (IAM_OWNER_VIEWER), plus the instance admin
  machine user created with the instance.
- **Actions** `complementTokenClaims` + `setIdentityClaimsUat`, copied from the shared instance
  with the new client id, on flow *complement token* → pre-userinfo and pre-access-token.
- **Human logins:** the 7 UAT employees' logins were copied with the **same user id, username,
  email and password hash**, so `employees.auth_subject` stayed valid and nobody's password
  changed. Each carries `suwalka_env=uat` + `suwalka_employee_id` metadata (auth #35's stamp).

## Cut-over behaviour

Tokens issued by the shared instance stop validating on UAT (the signing keys differ). Every UAT
user must **log out and log in once** per device, with the same password. The mobile app does not
redirect to login when its refresh fails — it keeps retrying the dead token, so a phone that has
not re-logged in looks broken (uploads fail with "Could not upload selfie"). Log out, log in.

## Rollback

Restore `suwalka-auth-secrets` (UAT) and **every applied** `*-uat` ApisixRoute from the cut-over
backup (four at cut-over: ai-services, auth, notification, org-hr — if more `*-uat` routes have
been applied since, repoint their discovery back too, or UAT ends up split across two issuers),
then restart `suwalka-auth` in `sfg-pos-app-uat`. The shared instance was not changed by
the cut-over, so UAT works on it again immediately (users log in once more).

## Known drift (pre-existing, not from this change)

The committed files for two **live** UAT routes do not match live, so do not re-apply them as-is:

- `routes/suwalka-org-hr-payroll-uat.yaml` lacks the live `/api/manpower/*` and `/api/probation/*`
  paths (and adds an `X-Env: uat` header live does not have).
- `routes/suwalka-auth-uat.yaml` lacks `OPTIONS` on the `/auth/admin/*` rule, which live has.

Re-applying either would remove working UAT behaviour. Reconcile git to live first.

## Still to do

- About a week after cut-over: on the **shared** instance, deactivate then delete the logins that
  only UAT used and the orphans left by the 2026-09-18 UAT wipe; drop `setIdentityClaimsUat` and
  the per-client-id mapping in `zitadel-actions/setIdentityClaims.js` (PR #59) — the shared
  instance then serves dev only.
- Reset `kalika@suwalka.com` on the shared instance for dev's own employee (a UAT reset rotated it
  before the split).
