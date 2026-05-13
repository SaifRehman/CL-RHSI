# CL-RHSI Demo

A working demo of **Red Hat Connectivity Link** (Kuadrant gateway policies: Auth, RateLimit, DNS, TLS) layered on top of **Red Hat Service Interconnect** (Skupper v2). Three apps span an OpenShift cluster and an external RHEL VM; the RHEL workload is joined into the cluster network via a Skupper VAN. The Istio Gateway (no sidecars) is the only dataplane at ingress, so every policy you see is a real Gateway API + Kuadrant CR — nothing is mocked.

## Architecture

```
                              Internet
                                 |
                                 v
                  +-----------------------------+
                  |  Istio Gateway prod-web     |
                  |  ingress-gateway namespace  |
                  |  (DNSPolicy + TLSPolicy)    |
                  +--+----------+-----------+---+
                     |          |           |
       app.travels.. |  todo.travels..      |  weather.travels..
                     |          |           |
                     v          v           v
              +----------+ +----------+ +------------------+
              | frontend | | todo-be  | | weather (Service)|
              | nginx    | | FastAPI  | | <-- Skupper VAN  |
              | demo-fe  | | demo-todo| | demo-weather     |
              +----------+ +----+-----+ +---------+--------+
                                |                 |
                          postgres:5432           | Skupper router
                          demo-db                 | (sites: 2)
                                                  v
                                          +----------------+
                                          | RHEL VM        |
                                          | podman:weather |
                                          | Skupper site   |
                                          +----------------+

Kuadrant policies attached:
  todo-route    : AuthPolicy (API key) + RateLimitPolicy (free 5/min, premium 30/min, per-userid)
  weather-route : AuthPolicy (API key) + RateLimitPolicy (10/min per request.host)
  app-route     : no policies (anonymous UI load)
```

## Hosts

| Host | Backend | Behind it |
|---|---|---|
| `app.travels.sandbox3259.opentlc.com` | `demo-frontend/frontend:80` | nginx-unprivileged serving vanilla JS UI |
| `todo.travels.sandbox3259.opentlc.com` | `demo-todo/todo-backend:8000` | FastAPI + asyncpg → PostgreSQL in `demo-db` |
| `weather.travels.sandbox3259.opentlc.com` | `demo-weather/weather:8080` | Skupper Listener → RHEL podman container running FastAPI + Open-Meteo proxy |

## Prereqs

- `oc` CLI logged in as cluster-admin (existing gateway `ingress-gateway/prod-web`, Kuadrant + Skupper v2 operators preinstalled).
- Python 3.12 (3.13 won't work — `asyncpg 0.29.0` has no 3.13 wheel and its sdist fails to compile).
- `podman` 5.x with a running `podman machine` on macOS (for building/pushing images locally).
- `skupper` v2 CLI on the laptop (any v2.x). The RHEL setup script auto-installs `skupper` v2.1.1 on the VM if missing.
- `sshpass` for non-interactive ssh to the RHEL VM:
  ```bash
  brew install hudochenkov/sshpass/sshpass
  ```
- Quay credentials with push rights to `quay.io/rh-ee-srehman/todo` and `quay.io/rh-ee-srehman/weather` (both public).
- OpenShift API token for the sandbox cluster.

## One-shot deploy

```bash
# 1. Build and push images to Quay
export QUAY_USER='rh-ee-srehman'
export QUAY_TOKEN='<your quay token>'
./scripts/build-push.sh

# 2. Deploy OCP side (namespaces, db, todo, frontend, skupper site, routes, policies)
oc login --token=<your-token> --server=<your-api-url>
./scripts/deploy-ocp.sh

# 3. Deploy RHEL side (rsync, install skupper v2 on VM, run weather container, link Skupper site)
./scripts/deploy-rhel.sh

# 4. End-to-end policy assertions (anonymous 401, free 5/min, premium 30/min, weather 10/min)
./scripts/test-policies.sh         # ~4 minutes
```

After `deploy-ocp.sh` completes, open `https://app.travels.sandbox3259.opentlc.com` in a browser.

## Demo flow

Real API keys (already provisioned in `kuadrant-system`, embedded in the frontend's `config.js`):

```
free:    ALICEFREE-3f8a7c2d-2b6e-4c0f-9a1d
premium: BOBPREMIUM-8d4e1a6f-4c9b-4b2e-b3c5
```

These are demo keys; they're not secrets. You can also pull them live:

```bash
oc -n kuadrant-system get secret api-key-free    -o jsonpath='{.data.api_key}' | base64 -d
oc -n kuadrant-system get secret api-key-premium -o jsonpath='{.data.api_key}' | base64 -d
```

Six-step story:

1. **Open the app** — `https://app.travels.sandbox3259.opentlc.com`. Show the green TLS padlock (cert managed by `prod-web-tls-policy`) and the DNS resolution (managed by `prod-web-dnspolicy` against the ELB).
2. **Tier dropdown = free** — type "buy milk" and hit Add a few times. After 5 todos within a minute, the next add returns `429 Too Many Requests` (rendered inline in the UI).
3. **Switch to premium** — same UI, but premium gets 30/min. Adds keep succeeding.
4. **Weather card** — type "Berlin", click Get Weather. The result comes back from the RHEL VM over the Skupper VAN. To prove it, ssh to the VM and `podman logs -f weather-app` while the audience clicks.
5. **No-auth curl** — show that `app-route` is open but `todo-route` is locked down:
   ```bash
   curl -sk https://app.travels.sandbox3259.opentlc.com/                # 200, HTML
   curl -sk https://todo.travels.sandbox3259.opentlc.com/api/todos      # 401
   curl -sk https://todo.travels.sandbox3259.opentlc.com/api/todos \
        -H "Authorization: APIKEY ALICEFREE-3f8a7c2d-2b6e-4c0f-9a1d"    # 200
   ```
6. **Weather rate-limit demo** — loop 12 calls; calls 11 and 12 return 429:
   ```bash
   for i in $(seq 1 12); do
     curl -sk -o /dev/null -w "%{http_code}\n" \
       "https://weather.travels.sandbox3259.opentlc.com/current?city=Berlin" \
       -H "Authorization: APIKEY ALICEFREE-3f8a7c2d-2b6e-4c0f-9a1d"
   done
   ```

## What was actually built

The implementation diverges from the original spec in nine documented places. Each one is small but worth knowing:

1. **PostgreSQL init-schema is not what creates the `todos` table.** The `rhel9/postgresql-16` image only runs `*.sh` files (not `*.sql`) from `/opt/app-root/src/postgresql-start/`, so the `init.sql` shipped in `manifests/10-db/03-init-configmap.yaml` is silently ignored. The `todos` table is actually created by `todo_backend.db.init_pool()` on first connection (a `CREATE TABLE IF NOT EXISTS`). Both paths are idempotent and the demo works fine.
2. **Skupper v2 CLI verb names.** The original `rhel/setup.sh` used v1 verbs (`skupper status`, `skupper link list`, `skupper connector list`). Skupper v2.1.1 uses `skupper site status`, `skupper link status`, `skupper connector status`, `skupper listener status`. The checked-in script uses the v2 forms.
3. **Skupper v2 podman needs `system install` + `system start`.** With v2 podman, `skupper site create` only writes declarations to disk — the router container doesn't actually start until you run `skupper system install` and `skupper system start`. Both calls are now in `rhel/setup.sh`.
4. **HOSTIP discovery on RHEL.** The spec assumed `host.containers.internal` would resolve, but rootless `podman 5.6.0` on RHEL 10 has no `podman0` bridge by default. `rhel/setup.sh` falls back to the VM's primary interface IP (e.g. `192.168.0.59`) and uses that as the connector host. The weather container is started with `-p 8080:8080`, so the host port reaches the container.
5. **Todo backend image layout.** `apps/todo_backend/Containerfile` uses `COPY . /app/todo_backend/` with a `.dockerignore` that excludes `tests/`, `__pycache__/`, `*.pyc`. Simpler than the per-file COPY in the original draft.
6. **`ALLOWED_ORIGIN` is required, not defaulted.** Both `apps/todo_backend/main.py` and `apps/weather/main.py` do `os.environ["ALLOWED_ORIGIN"]` — the process crashes at startup if unset. Deployments and the RHEL `podman run` set it explicitly. An earlier draft defaulted to the sandbox host, which was a bad default that would have shipped a hard-coded URL into the image.
7. **Weather rate-limit is per-route, not per-client-IP.** The spec called for a per-IP limit using `request.headers["x-forwarded-for"].split(",")[0]`, but that CEL expression fails to parse in Limitador v2.2.0 (nested quotes in the descriptor key). After trying several alternatives, the working expression is `request.host` — so the limit is "10 calls/minute across all callers of `weather.travels.sandbox3259.opentlc.com`". Still demonstrates a different limiting strategy from the tiered todo route, but the per-IP claim from the original spec does not hold on this Kuadrant version.
8. **Quay repos were already public.** `rh-ee-srehman/todo` and `rh-ee-srehman/weather` were created public on first push. No Quay visibility API call was needed.
9. **Local Python is 3.12, not 3.13.** Listed under prereqs above; `asyncpg 0.29.0` has no 3.13 wheel and its sdist fails to build against 3.13's removed `ob_digit`/`Py_SIZE` internals. The repo's `.venv/` is Homebrew Python 3.12.

## Repo layout

```
.
├── README.md                       # this file
├── apps/
│   ├── frontend/                   # index.html, app.js, style.css, config.js.template
│   ├── todo_backend/               # FastAPI + asyncpg, Containerfile, tests/
│   └── weather/                    # FastAPI + Open-Meteo client, Containerfile, tests/
├── manifests/
│   ├── 00-namespaces.yaml
│   ├── 10-db/                      # postgres secret, pvc, init configmap, deployment, service
│   ├── 20-todo/                    # db creds secret, deployment, service
│   ├── 30-frontend/                # nginx configmap (rendered at deploy), deployment, service
│   ├── 40-weather-skupper/         # Skupper Site, Listener, AccessGrant
│   ├── 50-routes/                  # 3 ReferenceGrants + 3 HTTPRoutes
│   └── 60-policies/                # API key secrets + 2x AuthPolicy + 2x RateLimitPolicy
├── rhel/
│   ├── setup.sh                    # installs skupper v2, builds image, runs container, joins VAN
│   └── link-token.yaml             # generated AccessToken (gitignored)
├── scripts/
│   ├── build-push.sh               # podman build + push for both apps
│   ├── deploy-ocp.sh               # applies all manifests, renders frontend configmap with live API keys
│   ├── deploy-rhel.sh              # rsync + ssh runner for rhel/setup.sh
│   ├── test-policies.sh            # curl-based assertions for all four policy paths
│   └── cleanup.sh                  # deletes namespaces + tears down RHEL site
└── docs/superpowers/
    ├── specs/2026-05-13-cl-rhsi-demo-design.md
    └── plans/2026-05-13-cl-rhsi-demo.md
```

## Troubleshooting

| Symptom | What to check |
|---|---|
| 401 even with the right `APIKEY` header | `oc -n demo-todo describe authpolicy todo-auth` (look for `Enforced: True`); verify the two secrets in `kuadrant-system` have label `kuadrant.io/auth-secret=true` and that the annotation keys are `kuadrant.io/groups` and `secret.kuadrant.io/user-id` |
| 429 on the very first call after deploy | Limitador may have stale counters from a prior run: `oc -n kuadrant-system rollout restart deploy/limitador-limitador` |
| Weather call hangs or returns 502 | `oc -n demo-weather get listener weather -o jsonpath='{.status.hasMatchingConnector}'` must be `true`; on the RHEL VM: `skupper site status`, `skupper link status`, `skupper connector status`. `accessgrant.skupper.io/weather-grant` must show `Ready` |
| `Pod ImagePullBackOff` on `todo-backend` or `weather` listener | Confirm `quay.io/rh-ee-srehman/todo` and `quay.io/rh-ee-srehman/weather` are **public** (browser → repo settings → public) |
| Frontend 404 / blank page | `oc -n demo-frontend get configmap frontend-static -o yaml` should contain `index.html`, `app.js`, `style.css`, `config.js`. The `config.js` is rendered at deploy time by `scripts/deploy-ocp.sh` from `apps/frontend/config.js.template` after reading the live API keys |
| HTTPRoute shows `Accepted: False` | `oc describe httproute <name>` — usually a missing ReferenceGrant in the backend namespace, or `parentRefs.namespace` doesn't match `ingress-gateway` |
| `skupper system start` fails on RHEL | `loginctl enable-linger lab-user`, then re-run. Skupper v2 podman site relies on user-level systemd |
| `skupper token redeem` fails with version mismatch | Verify both ends are v2.x: cluster controller image is `2.0.1-rh-2`, RHEL CLI installed by `rhel/setup.sh` is `2.1.1`. Wire-compatible per v2 release notes |
| Weather container can't reach Open-Meteo | The RHEL VM needs outbound HTTPS to `*.open-meteo.com`. `podman exec weather-app curl -sf https://api.open-meteo.com/v1/forecast?latitude=0&longitude=0&current=temperature_2m` |
| `ALLOWED_ORIGIN` KeyError in container logs | The Deployment/`podman run` must pass `-e ALLOWED_ORIGIN=https://app.travels.sandbox3259.opentlc.com`; same for the `weather:test` and `todo:test` smoke-test containers in `scripts/build-push.sh` (uses `-e ALLOWED_ORIGIN=https://test.example.com`) |

## Cleanup

```bash
./scripts/cleanup.sh
```

Deletes the four `demo-*` namespaces (which cascades to all manifests + Kuadrant policies + Skupper Site/Listener/AccessGrant), deletes the two API key secrets in `kuadrant-system`, and SSHes to the RHEL VM to `skupper system uninstall` + `podman rm -f weather-app`.
