# URL Shortener – Development Spec

> Author: Nihal Singh Atwal
  Student ID 49299175, 
  Email: nihalsingh.atwal@student.uq.edu.au

## 1. Overview and scope

Build a minimal URL shortener as 4 small Flask/nginx images (5 Deployments) plus MySQL and Redis, deployed on Kubernetes locally (kind) and on GKE. The app is deliberately tiny; the effort goes into the Kubernetes features that carry the marks: microservices, scaling, reliability, load balancing, orchestration and rollout/rollback.

**What the app does (5 user-facing functions):**

1. Register, log in and log out.
2. Create a short link for a long URL.
3. Visit a short link and get redirected (HTTP 302).
4. List and delete your own links.
5. Optional link expiry (`expires_in_hours` on create) and a QR code per link whose scans are counted separately (`?src=qr`).
6. View click stats per link (total, last click, last 7 days) and your top links.

**Out of scope (do not build):** custom aliases, password reset, email, OAuth, admin pages, rate limiting, a JS framework, a CSS framework, an ORM, message brokers other than Redis, service mesh, Helm charts, CI/CD.

**KISS rules for the implementing agent:**

- One file per concern; no service over \~200 lines of Python. Plain SQL via PyMySQL, no ORM.
- Small amounts of duplicated helper code (DB/Redis connection, auth check) are fine; do not create a shared library package.
- All configuration comes from environment variables. No config files inside images except nginx config.
- Every service listens on port 8000 (frontend nginx on 80) and exposes `GET /healthz` and `GET /readyz`.
- Every JSON error is `{"error": "<message>"}` with a sensible status code.
- Every shell command in scripts and the README gets a comment explaining what it does and its parameters (this is marked).
- If a choice is not covered here, pick the simplest option and note it in the README.

**Deadline:** submission is due 27 Oct 2026, 3 PM (one-week extension). Aim to have it running on GKE by 24 Oct to leave time for the proposal and demo rehearsal.

## 2. Architecture

One Ingress routes by path to four HTTP services; a fifth Deployment (analytics-worker) consumes click events from Redis. All state lives in MySQL and Redis. The editable draw.io source is `architecture.drawio` (attached in chat); keep it in the repo as `docs/architecture.drawio` for the proposal figure.

&#91;embedded content: Architecture · 1 Ingress, 5 app Deployments, MySQL, Redis\]

Not drawn, to keep the figure readable: redirect falls back to MySQL on a cache miss, and analytics-api validates session tokens in Redis.

**Request flows:**

1. **Create a link:** browser `POST /api/links` → Ingress → shortener → insert into MySQL `links` → `SET link:<code>` in Redis → `201` with the short URL.
2. **Follow a link:** browser `GET /<code>` → Ingress default backend → redirect → Redis `GET link:<code>` (MySQL on miss) → `LPUSH clicks` → `302`.
3. **Count a click:** analytics-worker `BRPOP clicks` → insert into MySQL `clicks` → increment `links.click_count`.
4. **View stats:** browser `GET /api/stats/<code>` → Ingress → analytics-api → aggregate `clicks` for the last 7 days → JSON.

## 3. Design decisions

Each decision trades purity for the least code that still demonstrates the marked feature.

| Decision | Why | Trade-off accepted |
| --- | --- | --- |
| Split redirect from link management | The redirect path is the hot, read-only path; isolating it lets the HPA scale only it, which is the clearest scaling demo. | One extra service to build. |
| Analytics split into API + worker Deployments from one image | Clicks are counted asynchronously so redirects stay fast; the worker scales independently of the stats API. Same image, different `command`, so no extra code base. | Two Deployments to manage. |
| Redis list as the click queue (`LPUSH` / `BRPOP`) | Redis is already needed for caching and sessions. `BRPOP` hands each event to exactly one worker, so multiple worker replicas are safe. | A click can be lost if a worker dies mid-event. Fine for analytics. |
| Opaque session tokens in Redis | Simpler than JWT (no signing keys, logout is a `DEL`). Any service can validate a token by reading Redis. | Sessions are lost if Redis restarts; users log in again. |
| Shared MySQL database, one schema | Avoids cross-service data sync. Each service only touches the tables it owns (see section 5). | Not strict database-per-service; mention as a production improvement in the proposal. |
| MySQL as a single-replica StatefulSet with a PVC | Cheapest and simplest persistent store inside the cluster. | Single point of failure for writes; Cloud SQL is the production answer. Redirects of cached links keep working while MySQL is down. |
| Redis as a single Deployment, no persistence | It only holds cache, sessions and a transient queue. | Restart clears sessions and in-flight events. |
| Same-origin routing through one Ingress | The UI and all APIs share one host, so there is no CORS, no API URL config in the frontend, and short links live at the domain root. | Path prefixes must not collide with short codes (reserved words, section 6). |
| Plain HTML + vanilla JS served by nginx | No build step, no framework; brutalist by design. | Basic look. |
| Kustomize base + `local` and `gke` overlays | Built into `kubectl`; the only differences between environments are image names and the Ingress. | One small concept to learn. |
| `X-Served-By` and `X-App-Version` response headers | Makes load balancing (pod names alternate) and rollouts/rollbacks (version changes) visible with `curl -I` during the demo. | None. |

## 4. Tech stack, repo layout and configuration

Python 3.12 + Flask + gunicorn for the three backend images, nginx for the frontend, MySQL 8.0 and Redis 7 from official images.

| Component | Image / tech | Port | Replicas (base) |
| --- | --- | --- | --- |
| `frontend` | `nginx:1.27-alpine` + static files | 80 | 2 |
| `shortener` | `python:3.12-slim`, Flask, gunicorn, PyMySQL, redis-py, werkzeug | 8000 | 2 |
| `redirect` | same base as shortener | 8000 | HPA 3 to 10 |
| `analytics-api` | `analytics` image, `gunicorn app:app` | 8000 | 2 |
| `analytics-worker` | `analytics` image, `python worker.py` | none | 2 |
| `mysql` | `mysql:8.0`, StatefulSet + 1 Gi PVC | 3306 | 1 |
| `redis` | `redis:7-alpine` | 6379 | 1 |

**Python dependencies (all three backends):** `flask`, `gunicorn`, `pymysql`, `redis`; the shortener also uses `qrcode` (SVG output, pure Python). Pin exact versions in each `requirements.txt`. Passwords use `werkzeug.security` (ships with Flask).

**Repo layout:**

```
urlshortener/
├── README.md                  # setup, deploy and demo instructions, every command commented
├── docker-compose.yml         # stage 1: run everything locally without Kubernetes
├── .env.example               # all env vars with dev defaults (copy to .env)
├── gateway/nginx.conf         # compose-only path router that mimics the Ingress
├── db/schema.sql              # tables + indexes, run once by MySQL on first start
├── frontend/                  # Dockerfile, nginx.conf, index.html, app.js, style.css
├── shortener/                 # Dockerfile, requirements.txt, app.py, common.py
├── redirect/                  # Dockerfile, requirements.txt, app.py, common.py
├── analytics/                 # Dockerfile, requirements.txt, app.py, worker.py, common.py
├── scripts/
│   ├── build.sh               # build all images with a given tag
│   ├── deploy-local.sh        # create kind cluster, load images, apply overlay
│   ├── deploy-gke.sh          # push images, apply overlay to GKE
│   ├── seed.py                # demo data: users, links, ~20,000 clicks
│   └── demo.sh                # the demo commands in order, commented
└── k8s/
    ├── base/                  # namespace, config, mysql, redis, 5 deployments, services, hpa
    └── overlays/
        ├── local/             # kind: ingress-nginx Ingress, local image names
        └── gke/               # GKE Ingress, static IP, ManagedCertificate, registry image names
```

`common.py` (copied into each backend, \~30 lines): `get_db()` returns a new PyMySQL connection, `get_redis()` returns a module-level Redis client, `current_user_id()` reads `Authorization: Bearer <token>` and returns the user id from Redis or `None`, `json_error(msg, status)`, and an `after_request` hook that adds the two headers below.

**Response headers on every backend response:** `X-Served-By: <pod hostname>` (from `socket.gethostname()`) and `X-App-Version: <APP_VERSION>`.

**Environment variables:**

| Variable | Used by | Dev default | Source in K8s |
| --- | --- | --- | --- |
| `DB_HOST` | backends | `mysql` | ConfigMap `app-config` |
| `DB_PORT` | backends | `3306` | ConfigMap |
| `DB_NAME` | backends, mysql (`MYSQL_DATABASE`) | `shortener` | ConfigMap |
| `DB_USER` | backends, mysql (`MYSQL_USER`) | `app` | ConfigMap |
| `DB_PASSWORD` | backends, mysql (`MYSQL_PASSWORD`) | `devpassword` | Secret `app-secret` |
| `MYSQL_ROOT_PASSWORD` | mysql | `devroot` | Secret `app-secret` |
| `REDIS_HOST` | backends | `redis` | ConfigMap |
| `REDIS_PORT` | backends | `6379` | ConfigMap |
| `BASE_URL` | shortener | `http://localhost:8080` | ConfigMap (overlay sets your domain) |
| `SESSION_TTL_SECONDS` | shortener | `86400` | ConfigMap |
| `CACHE_TTL_SECONDS` | shortener, redirect | `3600` | ConfigMap |
| `APP_VERSION` | all backends | `v1` | Baked into each image at build time (Dockerfile ARG + ENV), equal to the image tag; never set in K8s |

The frontend reads no env vars; its version is baked in at build time with `--build-arg APP_VERSION=v1` and written into `index.html`.

## 5. Data model

Three MySQL tables and three Redis key patterns. `db/schema.sql` is mounted into `/docker-entrypoint-initdb.d/` so MySQL creates the tables on first start (Compose: bind mount; K8s: ConfigMap `mysql-init`).

```sql
-- db/schema.sql
CREATE TABLE IF NOT EXISTS users (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  username      VARCHAR(50)  NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS links (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  code        VARCHAR(16)   NOT NULL UNIQUE,
  url         VARCHAR(2048) NOT NULL,
  user_id     INT           NOT NULL,
  click_count INT           NOT NULL DEFAULT 0,
  expires_at  DATETIME      NULL,                -- UTC; NULL = never expires
  created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  INDEX idx_links_user (user_id)
);

CREATE TABLE IF NOT EXISTS clicks (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  link_id    INT          NOT NULL,
  clicked_at DATETIME     NOT NULL,
  referrer   VARCHAR(255) NULL,
  user_agent VARCHAR(255) NULL,
  source     VARCHAR(8)   NOT NULL DEFAULT 'web', -- 'web' or 'qr'
  FOREIGN KEY (link_id) REFERENCES links(id) ON DELETE CASCADE,
  INDEX idx_clicks_link_time (link_id, clicked_at)
);
```

**Table ownership (who writes what):**

| Table | Written by | Read by |
| --- | --- | --- |
| `users` | shortener | shortener |
| `links` | shortener (insert, delete); analytics-worker (`click_count` only) | shortener, redirect, analytics-api |
| `clicks` | analytics-worker | analytics-api |

**Redis keys:**

| Key | Type | Value | TTL | Written by | Read by |
| --- | --- | --- | --- | --- | --- |
| `session:<token>` | string | user id | `SESSION_TTL_SECONDS` | shortener (login), deleted on logout | shortener, analytics-api |
| `link:<code>` | string | target URL | `CACHE_TTL_SECONDS` | shortener (on create), redirect (on cache miss) | redirect |
| `clicks` | list | JSON click event | none | redirect (`LPUSH`) | analytics-worker (`BRPOP`) |

Click event JSON (`source` is `qr` when the request has `?src=qr`, else `web`): `{"code": "aZ3k9Q", "source": "web", "ts": "2026-10-20T10:15:02Z", "referrer": "...", "user_agent": "..."}`. Truncate `referrer` and `user_agent` to 255 characters before pushing.

**Seed data (`scripts/seed.py`):** creates user `demo` / `demo1234`, 50 links, and about 20,000 `clicks` rows spread over the last 30 days with `click_count` updated to match. It writes straight to MySQL with batched `executemany`, so the stats charts and top-links list look realistic in the demo. Run it with `kubectl port-forward` to MySQL, or as a one-off `kubectl run` pod.

## 6. API endpoints and expected behaviour

All traffic enters through one host (e.g. `https://s.yourdomain.com`). The Ingress routes by path prefix; anything not matched goes to `redirect`.

| Path prefix | Routed to |
| --- | --- |
| `/ui` | frontend |
| `/api/auth`, `/api/links` | shortener |
| `/api/stats` | analytics-api |
| everything else (default backend) | redirect |

**Conventions for every endpoint:**

- Request and response bodies are JSON (`Content-Type: application/json`), except redirects and `204` responses.
- "Auth" = requires header `Authorization: Bearer <token>`. Missing, unknown or expired token returns `401 {"error": "unauthorized"}`.
- Errors: `{"error": "<message>"}`. Unknown routes return `404`.
- `GET /healthz` returns `200 {"status": "ok"}` without touching dependencies (liveness).
- `GET /readyz` runs `SELECT 1` on MySQL and `PING` on Redis; `200 {"status": "ready"}` or `503 {"status": "not ready"}` (readiness). These two are served on each pod's port 8000 and are not exposed through the Ingress paths above, except on `redirect`, which is harmless.

### 6.1 shortener (auth + link management)

| Method | Path | Auth | Request body | Success | Errors |
| --- | --- | --- | --- | --- | --- |
| POST | `/api/auth/register` | no | `{"username", "password"}` | `201 {"id", "username"}` | `400` invalid input, `409` username taken |
| POST | `/api/auth/login` | no | `{"username", "password"}` | `200 {"token", "username"}` | `400`, `401` bad credentials |
| POST | `/api/auth/logout` | yes | none | `204` | `401` |
| GET | `/api/auth/me` | yes | none | `200 {"id", "username"}` | `401` |
| POST | `/api/links` | yes | `{"url", "expires_in_hours"?}` | `201` link object | `400` invalid URL, `401` |
| GET | `/api/links` | yes | none | `200 [link object, ...]` newest first | `401` |
| GET | `/api/links/<code>/qr` | no | none | `200` SVG of `<BASE_URL>/<code>?src=qr` | `404` unknown code |
| PATCH | `/api/links/<code>` | yes | `{"url"?, "expires_in_hours"?}` (`null` clears expiry; absent keeps it) | `200` link object | `400`, `401`, `404` not found or not yours |
| DELETE | `/api/links/<code>` | yes | none | `204` | `401`, `404` not found or not yours |

Link object: `{"code": "aZ3k9Q", "url": "https://...", "short_url": "<BASE_URL>/aZ3k9Q", "click_count": 0, "created_at": "2026-10-20T10:15:02Z", "expires_at": null}`. `expires_in_hours` is an optional integer 1 to 8760; `400` otherwise. The Redis cache TTL is capped at the time left, and the redirect treats expired links as not found (`404`).

Behaviour:

- **Register:** username 3 to 50 chars of `[A-Za-z0-9_]`; password at least 8 chars. Store `generate_password_hash(password)`. Duplicate username returns `409`.
- **Login:** verify with `check_password_hash`. On success, `token = secrets.token_urlsafe(32)`, `SET session:<token> <user_id> EX SESSION_TTL_SECONDS`. Same `401` message for unknown user and wrong password.
- **Logout:** `DEL session:<token>`.
- **Create link:** URL must parse with `urllib.parse`, scheme `http` or `https`, have a host, and be at most 2048 chars. Generate `code` = 6 random chars from `[A-Za-z0-9]` via `secrets.choice`. Reject reserved codes (`ui`, `api`, `healthz`, `readyz`, case-insensitive) and retry up to 5 times on a `UNIQUE` collision. Insert the row, then `SET link:<code> <url> EX CACHE_TTL_SECONDS` to warm the cache. The same URL can be shortened more than once; each call gives a new code.
- **List links:** only the caller's links, `ORDER BY created_at DESC`, no pagination.
- **Delete link:** `DELETE ... WHERE code=%s AND user_id=%s`. If 0 rows, `404`. Then `DEL link:<code>` so the redirect stops working at once. Clicks cascade-delete.

### 6.2 redirect (hot path, read-only)

| Method | Path | Auth | Success | Errors |
| --- | --- | --- | --- | --- |
| GET | `/` | no | `302 Location: /ui/` | none |
| GET | `/<code>` | no | `302 Location: <target url>` | `404` plain-text page `Short link not found` |

Behaviour:

1. `GET link:<code>` from Redis. On hit, use it.
2. On miss, `SELECT url FROM links WHERE code=%s`. If found, `SET link:<code> <url> EX CACHE_TTL_SECONDS`. If not found, return `404`.
3. `LPUSH clicks <event json>` (section 5), then return the `302` with `Cache-Control: no-store` so browsers do not cache the redirect and every visit is counted.
4. If Redis is down, fall back to MySQL and skip the click event. If MySQL is down but Redis has the code cached, the redirect still works. Never return `500` for a cache or queue failure; log it and continue.

### 6.3 analytics-api (stats)

| Method | Path | Auth | Success | Errors |
| --- | --- | --- | --- | --- |
| GET | `/api/stats/<code>` | yes | `200` stats object | `401`, `404` not found or not yours |
| GET | `/api/stats/top?limit=10` | yes | `200 [{"code", "url", "click_count"}, ...]` highest first | `401` |

Stats object: `{"code", "url", "total_clicks", "last_click_at" (or null), "daily": [{"date": "2026-10-14", "clicks": 12}, ...]}`. `qr_clicks` is the all-time count with `source='qr'`; each `daily` entry also has `qr_clicks`. `daily` always has exactly 7 entries (today and the 6 previous days, UTC), oldest first, with zero-filled gaps. `total_clicks` = `links.click_count`. `limit` defaults to 10, max 50.

Auth check: read `session:<token>` from Redis (same as shortener), then filter by `links.user_id`.

### 6.4 analytics-worker (no HTTP API)

Loop forever: `BRPOP clicks 5`. For each event: look up `links.id` by `code` (skip silently if the link was deleted), `INSERT INTO clicks (...)`, `UPDATE links SET click_count = click_count + 1 WHERE id=%s`, commit. On a DB error, log and continue. Handle `SIGTERM` by finishing the current event and exiting, so rolling updates are clean. Liveness: `exec` probe that checks a heartbeat file `/tmp/heartbeat` touched every loop iteration is newer than 30 s.

## 7. Frontend (brutalist UI)

One page, three files, no build step: `index.html`, `app.js` (vanilla JS, `fetch`), `style.css` (under 40 lines). Served by nginx at `/ui/`.

**Look (revised):** minimal Material-style dark UI: left sidebar (Links, Top links), top bar with the user and log out, flat surfaces with 8-12 px radii, one violet accent, no gradients, inline SVG icons. Create, stats and QR open in `<dialog>`s. Stats show a stacked column chart (web vs QR per day) rendered as inline SVG, no chart library. `style.css` is no longer limited to 40 lines.

**Screen states (toggle by showing/hiding `<section>` elements):**

| State | Shown when | Contents |
| --- | --- | --- |
| Logged out | no token in `localStorage` or `/api/auth/me` returns `401` | Two forms side by side: Log in, Register. Register success logs in automatically. |
| Dashboard | valid token | Header line `logged in as <username> [log out]`; Create form (one URL input + `SHORTEN` button); links table; Top links list. |
| Stats panel | user clicks `stats` on a row | Below the table: total clicks, last click time, and a 7-day text bar chart in a `<pre>`, one line per day, e.g. `2026-10-20 ████████ 8`. A `close` button hides it. |

**Links table columns:** short URL (clickable `<a target=_blank>`), target URL (truncated to 60 chars with full URL in `title`), clicks, created, actions (`copy`, `stats`, `delete`). `copy` uses `navigator.clipboard.writeText`. `delete` asks `confirm()` first, then calls the API and re-renders.

**Behaviour:**

- One `api(method, path, body)` helper adds the `Authorization` header, parses JSON, and on `401` clears the token and shows the logged-out state.
- After create, prepend the new link and show the short URL in a message line above the table.
- Errors from the API are shown verbatim in a single message line (`<p id="msg">`). No alerts except the delete confirm.
- The table and top list refresh on load, after create, after delete, and when the user presses a `refresh` button. No polling.
- **Footer:** `frontend <APP_VERSION> · last API response served by <X-Served-By> (<X-App-Version>)`, updated after every API call. This makes load balancing and rollouts visible in the browser.

**nginx config (`frontend/nginx.conf`):** files copied to `/usr/share/nginx/html/ui/`; `location /ui/ { try_files $uri /ui/index.html; }`; `location = /healthz { return 200 'ok'; }`. Both `/healthz` and `/readyz` return `200` (nginx has no dependencies). All JS uses relative `/api/...` paths, so the same build works in Compose, kind and GKE.

## 8. Kubernetes manifests

Everything lives in namespace `urlshortener`. Base manifests are environment-neutral; overlays only change image names, `BASE_URL` and the Ingress. Local image names are `localhost/<name>:<tag>` (Podman's default naming, which kind keeps when loading archives).

**Base (`k8s/base/`):**

| File | Objects |
| --- | --- |
| `kustomization.yaml` | `namespace: urlshortener`, lists all files below |
| `namespace.yaml` | Namespace |
| `config.yaml` | ConfigMap `app-config` (all non-secret vars from section 4) |
| `mysql.yaml` | headless Service `mysql`, StatefulSet `mysql` (1 replica, 1 Gi `volumeClaimTemplates`, mounts ConfigMap `mysql-init` at `/docker-entrypoint-initdb.d`, readiness `exec mysqladmin ping -h 127.0.0.1`) |
| `redis.yaml` | Service `redis`, Deployment `redis` (1 replica, args `--save "" --appendonly no`, readiness `tcpSocket 6379`) |
| `shortener.yaml` | Deployment (2 replicas) + ClusterIP Service `shortener` |
| `redirect.yaml` | Deployment (no `replicas` field; the HPA owns it) + Service `redirect` |
| `analytics-api.yaml` | Deployment (2) + Service `analytics-api` |
| `analytics-worker.yaml` | Deployment (2), `command: ["python", "worker.py"]`, no Service, `exec` liveness on the heartbeat file |
| `frontend.yaml` | Deployment (2) + Service `frontend` |
| `hpa.yaml` | `autoscaling/v2` HPA on `redirect`: min 3, max 10, target CPU 50% |

Secret `app-secret` and ConfigMap `mysql-init` are **not** in the repo; the deploy scripts create them (from `.env` and `db/schema.sql`) with `kubectl create ... --dry-run=client -o yaml | kubectl apply -f -`, so they are idempotent and no password is committed.

**Every app Deployment follows this pattern** (shown for `redirect`; Services map port 80 to `targetPort: 8000`, frontend to 80):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redirect
spec:
  selector:
    matchLabels: {app: redirect}
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxSurge: 1, maxUnavailable: 0}   # zero-downtime rollouts
  template:
    metadata:
      labels: {app: redirect}
    spec:
      topologySpreadConstraints:                       # spread pods across nodes for reliability
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels: {app: redirect}
      terminationGracePeriodSeconds: 30
      containers:
      - name: redirect
        image: localhost/redirect:v1
        imagePullPolicy: IfNotPresent
        ports: [{containerPort: 8000}]
        envFrom: [{configMapRef: {name: app-config}}]
        env:
        - name: DB_PASSWORD
          valueFrom: {secretKeyRef: {name: app-secret, key: DB_PASSWORD}}
        resources:
          requests: {cpu: 100m, memory: 64Mi}            # HPA needs CPU requests
          limits: {cpu: 500m, memory: 256Mi}
        readinessProbe:
          httpGet: {path: /readyz, port: 8000}
          periodSeconds: 5
        livenessProbe:
          httpGet: {path: /healthz, port: 8000}
          initialDelaySeconds: 10
          periodSeconds: 10
        lifecycle:
          preStop: {exec: {command: ["sleep", "5"]}}    # let the load balancer drain before exit
```

Other app Deployments use `requests: {cpu: 50m, memory: 64Mi}`, `limits: {cpu: 250m, memory: 256Mi}`.

**Overlay `local` (kind):** `kustomization.yaml` (resources `../../base` + `ingress.yaml`; a ConfigMap patch setting `BASE_URL=http://localhost:8080`) and `ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shortener-ingress
spec:
  ingressClassName: nginx
  defaultBackend:
    service: {name: redirect, port: {number: 80}}
  rules:
  - http:
      paths:
      - {path: /ui,         pathType: Prefix, backend: {service: {name: frontend,      port: {number: 80}}}}
      - {path: /api/auth,   pathType: Prefix, backend: {service: {name: shortener,     port: {number: 80}}}}
      - {path: /api/links,  pathType: Prefix, backend: {service: {name: shortener,     port: {number: 80}}}}
      - {path: /api/stats,  pathType: Prefix, backend: {service: {name: analytics-api, port: {number: 80}}}}
      - {path: /,           pathType: Prefix, backend: {service: {name: redirect,      port: {number: 80}}}}
```

**Overlay `gke`:** same Ingress without `ingressClassName`, plus annotations `kubernetes.io/ingress.global-static-ip-name: shortener-ip` and `networking.gke.io/managed-certificates: shortener-cert`; `managed-cert.yaml` (`networking.gke.io/v1` ManagedCertificate for your domain); an `images:` block mapping each `localhost/<name>` to `australia-southeast1-docker.pkg.dev/<PROJECT_ID>/urlshortener/<name>` with `newTag: v1`; and a ConfigMap patch setting `BASE_URL=https://s.yourdomain.com`. GKE uses each pod's readiness probe path as the load balancer health check, which is why every service, including the frontend, serves `/readyz`.

HTTPS is optional for marks. If the certificate is not `Active` by demo day, remove the cert annotation and demo over HTTP on the static IP.

## 9. Step-by-step implementation plan

Work in order; do not start a step until the previous step's **Done when** passes. Steps 1 to 6 need no Kubernetes. The developer's machine is Fedora Silverblue with Podman, so commands use `podman`; `docker` works the same where noted.

1. **Scaffold the repo.** Create the layout from section 4, `.env.example`, `db/schema.sql` (section 5), and a stub `README.md`.
   - Done when: the tree matches section 4 and `.env.example` lists every variable.
2. **Compose: MySQL + Redis + gateway.** `docker-compose.yml` with `mysql` (mounts `db/schema.sql` into `/docker-entrypoint-initdb.d/`, named volume), `redis`, and `gateway` (`nginx:1.27-alpine` with `gateway/nginx.conf` routing the same prefixes as the Ingress in section 6, published on `localhost:8080`). Only the gateway publishes a port.
   - Done when: `podman-compose up -d mysql redis` starts and `SHOW TABLES` lists `users`, `links`, `clicks`.
3. **shortener service.** `common.py`, `app.py` with all section 6.1 endpoints plus `/healthz`, `/readyz`; Dockerfile (`python:3.12-slim`, non-root user, `gunicorn -w 2 -b 0.0.0.0:8000 app:app`).
   - Done when: through `localhost:8080` you can register, log in, create, list and delete a link with `curl`, and error cases return the codes in 6.1.
4. **redirect service.** `app.py` per 6.2, same Dockerfile pattern.
   - Done when: `curl -i localhost:8080/<code>` returns `302` with the right `Location`, `X-Served-By` and `X-App-Version`; an unknown code returns `404`; `LLEN clicks` in Redis grows by 1 per visit.
5. **analytics image (API + worker).** `app.py` per 6.3, `worker.py` per 6.4. Compose runs the image twice: `analytics-api` (gunicorn) and `analytics-worker` (`python worker.py`).
   - Done when: visits drain the `clicks` list to 0, rows appear in `clicks`, `click_count` increases, and `GET /api/stats/<code>` returns 7 `daily` entries.
6. **Frontend.** `index.html`, `app.js`, `style.css`, `nginx.conf` per section 7; Dockerfile copies files to `/usr/share/nginx/html/ui/` and replaces `__APP_VERSION__` in `index.html` with the build arg using `sed`.
   - Done when: every function in section 1 works in a browser at `http://localhost:8080/ui/`, and the footer shows pod hostname and version.
7. **Seed script.** `scripts/seed.py` per section 5, reading DB settings from env vars.
   - Done when: after seeding, the `demo` user sees 50 links, the top list is populated and stats charts show 7 days of data. `SELECT COUNT(*) FROM clicks` is about 20,000.
8. **Build script.** `scripts/build.sh <tag>` builds all four images as `localhost/<name>:<tag>`, passing `--build-arg APP_VERSION=<tag>` to every image.
   - Done when: `podman images` lists all four at the given tag.
9. **Base manifests.** Write `k8s/base/` per section 8.
   - Done when: `kubectl kustomize k8s/overlays/local` renders without errors and `kubectl apply --dry-run=server -k k8s/overlays/local` passes against the kind cluster from step 10.
10. **kind cluster + local deploy.** `kind-config.yaml`: 1 control-plane (label `ingress-ready=true`, `extraPortMappings` container 80 to host 8080, container 443 to host 8443, so rootless Podman needs no privileged ports) and 2 workers. `scripts/deploy-local.sh` (every line commented):
    - `KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --name shortener --config kind-config.yaml` (skip if it exists)
    - install ingress-nginx for kind and metrics-server, patching metrics-server with `--kubelet-insecure-tls`
    - for each image: `podman save localhost/<name>:<tag> -o /tmp/<name>.tar` then `kind load image-archive /tmp/<name>.tar --name shortener` (`kind load docker-image` does not work with Podman)
    - create `app-secret` from `.env` and `mysql-init` from `db/schema.sql` (idempotent, section 8)
    - `kubectl apply -k k8s/overlays/local`, then `kubectl rollout status` for every Deployment
    - Done when: all pods are `Running`/`Ready`, the app works at `http://localhost:8080/ui/`, and `kubectl get hpa -n urlshortener` shows a CPU percentage, not `<unknown>`.
11. **Local demo rehearsal.** Run every section 10 demo step against kind.
    - Done when: all acceptance checks in section 10 pass locally.
12. **GKE setup** (one-off, commented in `scripts/deploy-gke.sh` or README): enable `container.googleapis.com` and `artifactregistry.googleapis.com`; create Artifact Registry repo `urlshortener` in `australia-southeast1`; create a zonal Standard cluster with 3 `e2-medium` nodes in `australia-southeast1-a`; `gcloud container clusters get-credentials`; reserve global static IP `shortener-ip`; create an A record for `s.yourdomain.com` pointing to it.
    - Done when: `kubectl get nodes` shows 3 Ready nodes and `dig s.yourdomain.com` returns the static IP.
13. **GKE deploy.** `scripts/deploy-gke.sh <tag>`: tag and push the four images to Artifact Registry, create the Secret and `mysql-init` ConfigMap, `kubectl apply -k k8s/overlays/gke`, wait for rollouts.
    - Done when: `kubectl get ingress -n urlshortener` shows the static IP, the app works at `http://s.yourdomain.com/ui/` (and HTTPS once `kubectl describe managedcertificate` shows `Active`), and the seed script has been run against the cluster.
14. **Build v2 for the rollout demo.** Build `redirect` and `frontend` with tag `v2`; the only change is `APP_VERSION` (visible in the header and footer). Push to the registry, but do not deploy.
    - Done when: both `v2` images exist in Artifact Registry.
15. **Finish the README and demo script.** README: prerequisites, local run (Compose and kind), GKE deploy, demo steps, teardown (`gcloud container clusters delete`, release the static IP). `scripts/demo.sh` holds the section 10 commands in order, each commented, with a pause between steps.
    - Done when: someone else could deploy from the README alone, and every command in it has a comment.

## 10. Testing, demo and acceptance checklist

No unit-test suite is required. Testing is the `curl` checks in each step's **Done when**, plus the demo below run end to end on kind and then GKE. `HOST` is `http://localhost:8080` locally or `https://s.yourdomain.com` on GKE; `CODE` is a seeded short code.

**Demo script (`scripts/demo.sh`, fits the 4-minute presentation):**

1. **App tour (40 s):** in the browser, log in as `demo`, create a link, open it, show the stats panel and top links.
2. **Load balancing (20 s):** `for i in $(seq 6); do curl -sI $HOST/$CODE | grep X-Served-By; done` shows different pod names.
3. **Manual scaling (20 s):** `kubectl scale deploy/shortener --replicas=4 -n urlshortener`, then `kubectl get pods -n urlshortener -l app=shortener`.
4. **Autoscaling (45 s):** in one terminal `kubectl get hpa redirect -n urlshortener -w`; in another `hey -z 45s -c 50 -disable-redirects $HOST/$CODE`. Replicas rise above 3. (`-disable-redirects` stops `hey` from load-testing the target website.)
5. **Reliability (30 s):** keep `while true; do curl -s -o /dev/null -w "%{http_code}\n" $HOST/$CODE; sleep 0.2; done` running; `kubectl delete pod -l app=redirect -n urlshortener --wait=false`; output stays `302`. Optionally `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` on a node that does not run `mysql-0`, then `kubectl uncordon`.
6. **Rollout (30 s):** with the curl loop still running, `kubectl set image deploy/redirect redirect=<registry>/redirect:v2 -n urlshortener`; `kubectl rollout status`; `curl -sI $HOST/$CODE | grep X-App-Version` shows `v2`; no non-`302` responses.
7. **Rollback (20 s):** `kubectl rollout history deploy/redirect -n urlshortener`, `kubectl rollout undo deploy/redirect -n urlshortener`, version header back to `v1`.

Because `APP_VERSION` is baked into each image, `kubectl set image` alone creates exactly one new revision, which keeps `rollout history` and `rollout undo` clean. Annotate each rollout with `kubectl annotate deploy/redirect kubernetes.io/change-cause="v2" -n urlshortener` so the history is readable.

**Acceptance checklist mapped to the marking criteria:**

| Criterion (marks) | Evidence in this build | Check |
| --- | --- | --- |
| Frontend: interactive UI (1) | Section 7 page | Demo step 1 |
| Backend: database design and usage (1) | 3 tables with FKs and indexes, Redis cache/sessions/queue | Show `schema.sql` and table counts |
| At least 4 functionalities (1) | Register/login/logout, create, redirect, list/delete, stats | Demo step 1 |
| Microservices and containerization (2) | 4 images, 5 app Deployments + MySQL + Redis, each in its own containers | `kubectl get deploy,sts -n urlshortener` |
| Scalability (1) | `kubectl scale` + HPA on redirect | Demo steps 3 and 4 |
| Reliability (1) | 2+ replicas spread across nodes, probes, cache fallback | Demo step 5 |
| Load balancing (1) | Ingress + ClusterIP Services across pods | Demo step 2 |
| Orchestration (3) | Kubernetes on GKE: Deployments, StatefulSet, Services, Ingress, ConfigMap, Secret, HPA, PVC | `kubectl get all,ingress,pvc,hpa -n urlshortener` |
| Rollout and rollback (1) | RollingUpdate `maxUnavailable: 0`, revision history | Demo steps 6 and 7 |
| Originality and completeness (3) | Async click analytics with worker scaling, cache-first redirect, real domain | Whole demo; matches proposal |
| Commented commands (deduction if missing) | Every command in README and scripts commented | Review before submission |
| Cloud deployment (deduction if missing) | Running on GKE at your domain | Demo runs against GKE |
