# Gateway CD — why it does not auto-apply yet

Status 2026-08-19. Written after `POST /api/grievances` was found 404ing in production
**eight days after the PR that fixed it was merged** (#50, merged to `dev` 2026-08-18).

## The short version

Merging a route PR in this repo has never deployed anything to Cantech. There is no
mechanism — not a broken one, an absent one. Every route now serving on Cantech was
hand-applied with `kubectl`.

## Why `cd.yaml` does not do it

`.github/workflows/cd.yaml` is real, and it is wrong in three independent ways:

1. **No push trigger.** It is `workflow_dispatch` only, by design — its own comment reads
   *"a gateway should not redeploy on every push."*
2. **It targets the retired cluster.** It writes `DOKS_KUBECONFIG` and deploys namespace
   `sfg-gateway` on DigitalOcean. Live is Cantech `sfg-prod` / `sfg-pos-app`.
3. **Its runner never picks it up.** Last *successful* CD run: **2026-07-09**. Every run
   since is `cancelled`, and CI runs sit `queued` indefinitely while other sfg-labs repos
   build fine on the same box. This is scoping/starvation specific to this repo — Actions
   is enabled and the repo is not archived.

Fixing only #1 would be worse than leaving it alone: it would auto-apply files that have
drifted, and see below for what that costs.

## Why auto-apply is dangerous *today*

**An ApisixRoute apply REPLACES `spec.http`. It does not merge into it.** A file that has
drifted behind the cluster does not fail — it silently deletes the live rules it lacks.

**The APISIX ingress controller here watches ALL namespaces** (no `namespace_selector` in
`sfg-apisix-ingress-config`). So a file declaring the wrong namespace does not update the
serving route — it creates a *second* ApisixRoute competing for the same paths on the same
host, and both are `Accepted=True`.

Both failure modes are already on the record:

| when | what happened |
|---|---|
| until 2026-08-19 | `routes/suwalka-org-hr-payroll.yaml` was missing `/api/manpower/*` and `/api/probation/*`, both serving. Applying it would have deleted them. |
| 2026-08-19 05:08 UTC | `routes/public.yaml` was applied. Because it declares `sfg-labs`, it created a duplicate `public-routes-suwalka` there, shadowing six paths already served from `sfg-pos-app`. No traffic broke — the `sfg-pos-app` copy still wins — but which copy wins is not pinned. |
| 2026-08-19 05:08 UTC | Same apply created `sfg-apps/public-routes-apps` and an `sfg-labs/zimma-api` whose backends (`baithak-api`, `cms-api`, `zimma-api`) do not exist in those namespaces. The controller logged `failed to translate ApisixRoute backend` — while still reporting `Accepted=True` on the object. **`Accepted=True` does not mean the route is serving.** |

## Current reconciliation debt

Output of the namespace guard in `cd-cantech.yaml`, run against `sfg-prod` on 2026-08-19:

```
OK        (2)  suwalka-org-hr-payroll.yaml, public.yaml
DUPLICATE (7)  admin-web.yaml, nma-engine.yaml, suwalka-ai-services.yaml,
               suwalka-auth.yaml, suwalka-notification.yaml, zimma-api.yaml,
               zimma-web.yaml
               — each declares a namespace the object does NOT serve from,
                 so applying creates a competitor rather than an update
CREATE    (9)  admin-web-dev, baithak, cms, suwalka-customer-vehicle,
               suwalka-incentive, suwalka-inventory-pricing, suwalka-platform,
               suwalka-sales, suwalka-tasks, suwalka-workshop
               — no such object anywhere; most have no backing Service either
```

Caveat on the two `OK`s: `public.yaml` reads OK **because** this morning's apply already
created its `sfg-labs` object. The guard answers "does the object exist where this file
says", not "should it exist there". It cannot detect a duplicate that already landed.

## Branch fork

No branch describes the cluster. `routes/` differs between `main` and `dev`:

- `main` — the two careers public rules (189 lines of `public.yaml`); **no** grievances root
- `dev` — grievances root; **no** careers rules
- `feat/probation-gateway-route` (PR #49, open → `main`) — manpower + probation; **no** grievances root

`dev` is the default branch and the one CD should follow. The careers rules must be carried
onto `dev` before `public.yaml` is ever applied from it, or the careers page loses its
no-auth carve-out and silently returns zero jobs.

## The order this has to happen in

1. **Reconcile each file to the live object until `kubectl diff` exits 0.** Done for
   `suwalka-org-hr-payroll.yaml`. Seven duplicates and the branch fork remain.
2. **Delete the duplicate `sfg-labs/public-routes-suwalka`** created 2026-08-19, once
   `public.yaml` is reconciled to `sfg-pos-app`. Needs a maintenance window: it is a live
   object, even if currently losing the match.
3. **Fix the runner starvation** — until then `cd-cantech.yaml` cannot run even when
   dispatched. Needs org-level runner access.
4. **Only then** flip `cd-cantech.yaml`'s default from `plan` to `apply` on push.

Until step 4, a route change is still **two PRs and one deliberate manual act**. Treat any
merged route PR as undeployed until proven otherwise.

## Proving a route is actually live

Read the **body**, never the status code — both are 404:

- `{"error_msg":"404 Route Not Found"}` → APISIX has no route. The gateway half is not applied.
- `{"error":1,"code":...}` → app envelope; the route works, something else is wrong.

Always probe with the **method the rule allows**. APISIX returns `404 Route Not Found` on a
method mismatch, which is indistinguishable from a missing route — `zimma-webhooks` is
POST-only, and a GET against it looks exactly like an outage that is not there.
