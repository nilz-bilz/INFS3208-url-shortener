# URL Shortener (INFS3208)

Stub README, finished in spec step 15. Spec: `docs/SPEC.md`.

## Run locally with Compose (stage 1)

```bash
# Create your local env file from the dev defaults (cp = copy)
cp -n .env.example .env

# Build images and start everything in the background (-d detached, --build rebuild images)
podman-compose up -d --build

# Show container state
podman-compose ps

# Load demo data (-T: no TTY, so stdin can feed the script into the shortener container)
podman-compose exec -T shortener python - < scripts/seed.py
```

App: http://localhost:8080/ui/ (demo login: `demo` / `demo1234` after seeding).

```bash
# Stop and remove containers; add -v to also delete the MySQL volume
podman-compose down
```

## Decisions

- MySQL runs with `--authentication-policy=mysql_native_password` so PyMySQL can log in without adding the `cryptography` package. The Kubernetes `mysql.yaml` must pass the same arg.
- Expiry and QR codes were added after the original spec (SPEC.md updated). QR codes are rendered server-side by the shortener with `qrcode`; scans carry `?src=qr` and are stored as `clicks.source`.
- Existing Compose databases need the new columns: either `podman-compose down -v` (wipes data) and up again, or run the two `ALTER TABLE` statements: `links ADD COLUMN expires_at DATETIME NULL`, `clicks ADD COLUMN source VARCHAR(8) NOT NULL DEFAULT 'web'`.
- `/healthz` and `/readyz` plus the JSON error handlers live in `common.py` (`register_common`) to avoid repeating them in `app.py`.
