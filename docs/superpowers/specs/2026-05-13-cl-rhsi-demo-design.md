# CL-RHSI Demo Design

Date: 2026-05-13
Status: Approved

## Goal

Showcase Red Hat Connectivity Link (Kuadrant) gateway policies — Auth, RateLimit, DNS, TLS — applied across microservices that span an OpenShift cluster and an external RHEL VM, with the RHEL workload joined into the cluster network via Red Hat Service Interconnect (Skupper v2). Service Mesh sidecars are NOT used; the Istio Gateway alone is the dataplane at ingress.

## Existing cluster state

- Gateway `ingress-gateway/prod-web` (gatewayClassName `istio`), listener `*.travels.sandbox3259.opentlc.com`, HTTPS terminate with secret `api-tls`, real public ELB hostname assigned.
- Gateway already has `prod-web-dnspolicy` and `prod-web-tls-policy` attached (wildcard DNS + cert).
- Kuadrant operator installed in `kuadrant-system`; AuthPolicy, RateLimitPolicy, DNSPolicy, TLSPolicy, AuthConfig, Authorino, Limitador CRDs present.
- Skupper v2 (controller `2.0.1-rh-2`) installed; CRDs `sites/listeners/connectors/links/accessgrants/accesstokens` present. An unrelated Skupper site exists in `identity-db` for a YugabyteDB demo — leave untouched.
- Reference HTTPRoute pattern: `echo-api/echo-api` (host `echo.travels.sandbox3259.opentlc.com`).

## RHEL VM

- Host: `rhel.rfztg.sandbox2786.opentlc.com`, user `lab-user`, password-auth.
- Has `podman` (assumed; verified on first connect).
- Will run: one weather container, and a Skupper v2 podman site joined to the cluster site via `AccessGrant`/`AccessToken`.

## Components

### Frontend — namespace `demo-frontend`

- Vanilla HTML/CSS/JS served by `nginxinc/nginx-unprivileged:1.27-alpine` (runs as non-root for OpenShift restricted SCC).
- UI features:
  - Tier dropdown: `free` / `premium` — selects which API key the browser attaches.
  - Todo list panel: add, list, toggle complete, delete; calls `https://todo.travels.sandbox3259.opentlc.com/api/todos`.
  - Weather card: city input + fetch button; calls `https://weather.travels.sandbox3259.opentlc.com/current?city=...`.
  - Surfaces 401/429 responses inline so policy effects are visible to the demo audience.
- Backend URLs and API keys are injected via a `ConfigMap`-rendered `config.js` (so they aren't hard-coded into static files). The deploy script reads the two `api_key` values out of the `kuadrant-system` secrets after they're generated and renders `config.js` with the real values before applying the ConfigMap.
- Resources: Deployment (1 replica), Service (port 80), ConfigMap (`index.html`, `style.css`, `app.js`, `config.js`).

### Todo backend — namespace `demo-todo`

- Python 3.12 + FastAPI + asyncpg, packaged as a container image.
- Endpoints:
  - `GET /healthz` → `{"ok": true}`
  - `GET /api/todos` → list
  - `POST /api/todos` body `{"title": "..."}` → create
  - `PUT /api/todos/{id}` body `{"title?", "completed?"}` → update
  - `DELETE /api/todos/{id}` → delete
- DB connection from env: `PG_HOST`, `PG_DB`, `PG_USER`, `PG_PASSWORD` (mounted from secret `postgres-creds` projected across namespaces, or via per-namespace secret created at deploy time).
- CORS: allow origin `https://app.travels.sandbox3259.opentlc.com` on both the todo backend and the weather service (since the browser hits them cross-origin).
- Resources: Deployment (1 replica), Service (port 8000), Secret with DB creds, container image built locally and pushed to OpenShift internal registry (`image-registry.openshift-image-registry.svc:5000/demo-todo/todo-backend:latest`) via `oc new-build`/`BuildConfig` or `oc start-build` from local files.

### Database — namespace `demo-db`

- `registry.redhat.io/rhel9/postgresql-16` (or upstream `postgres:16-alpine`) as a Deployment with a PVC (1Gi).
- Secret `postgres-creds`: `POSTGRESQL_USER=todo`, `POSTGRESQL_PASSWORD=<gen>`, `POSTGRESQL_DATABASE=todos`.
- An init `ConfigMap` mounted at `/docker-entrypoint-initdb.d/init.sql` creates the `todos` table.
- Service `postgres:5432` (ClusterIP). The Service is reachable cross-namespace from `demo-todo` (no NetworkPolicy restrictions added in this demo).

### Weather (cluster side) — namespace `demo-weather`

- Skupper v2 `Site` CR with `linkAccess: default` (so the RHEL podman site can link in).
- `Listener` CR: routingKey `weather`, port `8080`, host `weather` — this materializes a cluster Service named `weather:8080` whose endpoints are the Skupper router; traffic for that port is carried over the VAN to whichever site has a matching `Connector` for routing key `weather` (the RHEL podman site).
- The HTTPRoute on host `weather.travels...` points at this `weather` Service.

### Weather (RHEL side)

- Python 3 + FastAPI app (`weather/main.py`) packaged as a container, built with `podman build` on RHEL.
  - Endpoint `GET /current?city=X`:
    1. Geocode the city via `https://geocoding-api.open-meteo.com/v1/search?name=X&count=1`.
    2. Fetch current weather via `https://api.open-meteo.com/v1/forecast?latitude=...&longitude=...&current=temperature_2m,wind_speed_10m,weather_code`.
    3. Return `{"city", "temp_c", "wind_kph", "weather_code", "description"}`.
  - Endpoint `GET /healthz` → `{"ok": true}`.
  - CORS: allow `https://app.travels.sandbox3259.opentlc.com`.
- Run via `podman run -d --name weather-app --restart=unless-stopped -p 127.0.0.1:8080:8080 weather:latest`.
- Skupper v2 podman site joined to the cluster via redeemed `AccessGrant`. Connector with routingKey `weather`, host `host.containers.internal` (or the bridge IP), port `8080`.

## Ingress topology

Three HTTPRoutes, each attached to `ingress-gateway/prod-web`:

| Host | HTTPRoute (ns/name) | Match | Backend |
|---|---|---|---|
| `app.travels.sandbox3259.opentlc.com` | `demo-frontend/frontend-route` | `/` (prefix) | `frontend:80` |
| `todo.travels.sandbox3259.opentlc.com` | `demo-todo/todo-route` | `/api/todos`, `/healthz` (prefix) | `todo-backend:8000` |
| `weather.travels.sandbox3259.opentlc.com` | `demo-weather/weather-route` | `/current`, `/healthz` (prefix) | `weather:8080` |

A `ReferenceGrant` in each app namespace permits the gateway (`Gateway/prod-web` in `ingress-gateway`) to reference its Services.

DNS records (`app.`, `todo.`, `weather.` A/CNAME pointing at the ELB) are managed automatically by the existing `prod-web-dnspolicy`, which wildcards the listener hostname. TLS termination uses the wildcard cert managed by `prod-web-tls-policy`. We add no new DNS/TLS policies; we just demo them in the README.

## Kuadrant policies

### API key secrets (in `kuadrant-system`)

Two secrets, both labeled `kuadrant.io/auth-secret=true` and annotated with user identity + group:

- `api-key-free` — `api_key=IAMALICEFREE...` (32-char random), annotations `kuadrant.io/groups=free`, `secret.kuadrant.io/user-id=alice`.
- `api-key-premium` — `api_key=IAMBOBPREMIUM...`, annotations `kuadrant.io/groups=premium`, `secret.kuadrant.io/user-id=bob`.

### AuthPolicy `todo-auth` (in `demo-todo`, targetRef `HTTPRoute/todo-route`)

```yaml
rules:
  authentication:
    api-key-users:
      apiKey:
        selector:
          matchLabels:
            kuadrant.io/auth-secret: "true"
        allNamespaces: true
      credentials:
        authorizationHeader:
          prefix: APIKEY
  response:
    success:
      filters:
        identity:
          json:
            properties:
              userid: { selector: auth.identity.metadata.annotations.secret\.kuadrant\.io/user-id }
              groups: { selector: auth.identity.metadata.annotations.kuadrant\.io/groups }
```

Behavior: missing/invalid header → 401. Successful auth makes `auth.identity.userid` and `auth.identity.groups` available to the RateLimitPolicy.

### AuthPolicy `weather-auth` (in `demo-weather`, targetRef `HTTPRoute/weather-route`)

Identical structure to `todo-auth`. Same API keys work on both routes; this demonstrates per-route AuthPolicy attachment with shared identity.

### RateLimitPolicy `todo-ratelimit` (in `demo-todo`, targetRef `HTTPRoute/todo-route`)

Two limits, distinguished by `groups`:

```yaml
limits:
  free-tier:
    rates: [{ limit: 5, window: 1m }]
    when:
      - predicate: "auth.identity.groups == 'free'"
    counters:
      - expression: auth.identity.userid
  premium-tier:
    rates: [{ limit: 30, window: 1m }]
    when:
      - predicate: "auth.identity.groups == 'premium'"
    counters:
      - expression: auth.identity.userid
```

### RateLimitPolicy `weather-ratelimit` (in `demo-weather`, targetRef `HTTPRoute/weather-route`)

A simpler IP-based limit to demonstrate a non-identity strategy on the same gateway:

```yaml
limits:
  per-ip:
    rates: [{ limit: 10, window: 1m }]
    counters:
      - expression: request.headers["x-forwarded-for"].split(",")[0]
```

### No policies on frontend

The `app.travels...` HTTPRoute has no AuthPolicy/RateLimitPolicy. The UI must load for anonymous visitors — auth/limits live on the API hosts.

## Skupper VAN flow

1. `oc apply` `Site` CR in `demo-weather` with `linkAccess: default` → cluster Skupper router comes up with externally reachable endpoints.
2. `oc apply` `Listener` (routingKey `weather`, port 8080, host `weather`) — materializes a `weather` Service in the namespace.
3. Generate cluster-side token: `oc apply` `AccessGrant` named `weather-grant`, then read its issued token and write `link-token.yaml` (an `AccessToken` resource) for the RHEL site.
4. On RHEL:
   - `skupper site create cl-rhsi-rhel --enable-link-access=false` (RHEL only connects out — no inbound link access needed).
   - `skupper token redeem ./link-token.yaml` to establish the link to the cluster.
   - `skupper connector create weather 8080 --host host.containers.internal` so `routingKey=weather` resolves to the local podman container.
5. Verify with `skupper status` on both sides — `sitesInNetwork: 2`, link operational, weather routing key has connector + listener.

## Repository layout

```
/
├── README.md                      # Demo runbook (replaces existing README)
├── docs/superpowers/specs/        # This file lives here
├── apps/
│   ├── frontend/
│   │   ├── index.html
│   │   ├── style.css
│   │   ├── app.js
│   │   └── config.js.template
│   ├── todo-backend/
│   │   ├── main.py
│   │   ├── db.py
│   │   ├── requirements.txt
│   │   └── Containerfile
│   └── weather/
│       ├── main.py
│       ├── requirements.txt
│       └── Containerfile
├── manifests/
│   ├── 00-namespaces.yaml
│   ├── 10-db/                     # postgres deployment, pvc, service, secret, init configmap
│   ├── 20-todo/                   # backend deployment, service, configmap, secret, build
│   ├── 30-frontend/               # nginx deployment, service, configmap (static files), build
│   ├── 40-weather-skupper/        # skupper Site + Listener, weather Service is auto-created
│   ├── 50-routes/                 # 3 HTTPRoutes + 3 ReferenceGrants
│   └── 60-policies/               # API key secrets + AuthPolicy + RateLimitPolicy CRs
├── rhel/
│   ├── weather/                   # same source as apps/weather copied into rhel deploy bundle
│   ├── podman-run.sh              # builds image + runs container
│   └── skupper-setup.sh           # creates podman skupper site + redeems token + creates connector
└── scripts/
    ├── deploy-ocp.sh              # applies manifests in order, builds images via oc, waits for ready
    ├── deploy-rhel.sh             # rsyncs rhel/ to the VM and runs setup over ssh
    ├── test-policies.sh           # curl-based demo: no key → 401, free → 5/min limit, premium → 30/min, weather IP limit
    └── cleanup.sh                 # deletes namespaces + RHEL containers/site
```

## Demo runbook (README content outline)

1. **Prereqs check** — `oc login`, `ssh lab-user@rhel...` reachable, `skupper` CLI v2 installed locally.
2. **Deploy OCP** — `./scripts/deploy-ocp.sh`. Watch gateway routes get `Accepted: true`.
3. **Deploy RHEL** — `./scripts/deploy-rhel.sh` (rsync sources, build image, run container, set up Skupper podman site, redeem link). Verify `skupper status` shows 2 sites in network.
4. **Open browser** — `https://app.travels.sandbox3259.opentlc.com`. Show TLS cert (managed by TLSPolicy), DNS record (managed by DNSPolicy).
5. **Demo auth** — `curl -k https://todo.travels.../api/todos` without header → `401 Unauthorized`. With header `Authorization: APIKEY <free key>` → 200.
6. **Demo rate-limit** — Loop 7× free key → first 5 succeed, 6th/7th return `429 Too Many Requests`. Same loop with premium key → all succeed up to 30.
7. **Demo weather over Skupper** — `curl -k 'https://weather.travels.../current?city=Berlin' -H 'Authorization: APIKEY <key>'`. On RHEL, tail `podman logs -f weather-app` to show the request landing locally.
8. **Demo IP rate-limit** — Loop weather 12× → 11th/12th return 429.
9. **Cleanup** — `./scripts/cleanup.sh`.

## Out of scope

- Istio sidecars on application workloads (Service Mesh is installed but not used for the dataplane between services).
- OIDC / Keycloak (using API keys for identity).
- mTLS between intra-cluster services.
- CI/CD pipelines, GitOps, Argo applications.
- Multi-region failover, multi-cluster geo routing.
- Network policies beyond OpenShift defaults.

## Risks & mitigations

- **Wildcard cert may not cover newly created subdomains immediately.** `prod-web-tls-policy` is set to manage the listener hostname `*.travels...`, so any host under that wildcard is covered by the existing cert. Verify with `curl -kv` on first call.
- **Skupper podman site requires user-level systemd or persistent process.** Use `skupper site create --platform podman` and the auto-generated systemd user unit; document `loginctl enable-linger lab-user` so it survives logout.
- **OpenShift restricted SCC blocks nginx official image** (binds port 80 as root). Use `nginxinc/nginx-unprivileged` listening on 8080, with Service port 80 → targetPort 8080.
- **Image builds on cluster** — use `oc new-build --binary` + `oc start-build --from-dir` to avoid needing an external registry. Stream source from local laptop.
- **Skupper version mismatch** (cluster 2.0.1, local CLI 2.1.1) — should be wire-compatible per Skupper v2 release notes; if `skupper token redeem` fails, fall back to manifest-only token transfer (apply `AccessToken` YAML directly on RHEL podman site).
