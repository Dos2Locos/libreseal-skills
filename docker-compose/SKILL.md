---
name: docker-compose
description: |
  Deploy LibreSeal (self-hosted secrets manager, independent fork of Phase Console) with Docker Compose.
  Triggers: "deploy LibreSeal", "self-host LibreSeal with Docker", "install LibreSeal in my homelab",
  "LibreSeal Docker Compose setup", "back up LibreSeal", "upgrade LibreSeal",
  "get a Let's Encrypt certificate for LibreSeal".
---

# Deploy LibreSeal with Docker Compose

This skill installs LibreSeal from its source repository (`https://github.com/Dos2Locos/libreseal`) using the repository's own scripts, verifies it, and optionally replaces the bundled self-signed certificate with a Let's Encrypt one. Images are built locally; nothing is pulled from Phase.

The agent runs commands directly. The user handles anything that involves their credentials, passwords or recovery phrase.

## Important Principles

- **Never handle secrets.** `scripts/libreseal-init.sh` generates every secret into `.env` (mode 600) without printing it. Never `cat`, `grep`, print or copy `.env`, backups or tokens. If OAuth/OIDC credentials are needed, tell the user which variable names to fill in `.env` themselves.
- **Never overwrite an existing installation.** If `.env` or running `libreseal-*` containers exist, treat it as an existing deployment: do not rerun init, do not run `docker compose down -v`.
- **Homelab first.** A LAN hostname with the bundled self-signed certificate is a valid end state. Let's Encrypt is optional and needs a public domain.
- **Preserve nginx routing.** Any change to `nginx/default.conf` must keep `/service/` → `backend:8000` and `/` → `frontend:3000`.
- **Reference files for details.** `refs/docker-compose-deployment.md` has templates and commands; `refs/troubleshooting.md` covers failures.

## Workflow

### Phase 1 — Prerequisites (run without asking)

1. `docker --version` and `docker compose version` — if missing, point the user to https://docs.docker.com/engine/install/ and stop.
2. `git --version` and `openssl version` — required by the setup script.
3. Check for an existing deployment: `docker ps --filter name=libreseal- --format '{{.Names}}'`. If containers exist, skip to Phase 5 (verification) or the task the user asked for.
4. Check that the chosen host ports are free, e.g. `ss -ltn` (Linux) or `lsof -nP -iTCP -sTCP:LISTEN` (macOS). Default ports are 80 and 443; pick others (e.g. 8080/8443) if busy.

### Phase 2 — Questions (single message)

1. **Hostname** users will type (LAN name such as `secrets.lan`, an IP, or a public domain). No scheme, no port.
2. **Ports** — HTTPS (default 443) and HTTP (default 80).
3. **Sign-in** — password sign-in is enabled by default. Optional instance-wide providers: `google`, `github`, `gitlab`, `authentik`, `authelia`. (Organisation-level Entra ID/Okta SSO, SCIM, dynamic secrets, rotation and log streams are not available in LibreSeal.)
4. **Public domain with Let's Encrypt?** Only if the hostname is a public DNS name reachable on port 80.

### Phase 3 — Install

```bash
git clone https://github.com/Dos2Locos/libreseal.git
cd libreseal
# Optional: pin a verified commit or tag from the README "Verified combination" table
./scripts/libreseal-init.sh --host {HOST} --https-port {HTTPS_PORT} --http-port {HTTP_PORT}
```

The script refuses to overwrite an existing `.env`. If providers were requested, tell the user to set in `.env` (themselves, with an editor): `SSO_PROVIDERS=...` and the matching `*_CLIENT_ID` / `*_CLIENT_SECRET` (and `AUTHENTIK_URL`/`AUTHELIA_URL`). Callback URLs are listed in `refs/docker-compose-deployment.md`. Wait for confirmation.

```bash
docker compose up -d --build
```

The first build takes several minutes (frontend build needs ~4 GB RAM).

### Phase 4 — Verify

```bash
docker compose ps                     # all services running; backend and postgres healthy
docker compose ps -a migrations       # exited with code 0
curl -ksS https://{HOST}:{HTTPS_PORT}/service/health/
curl -ks -o /dev/null -w '%{http_code}\n' https://{HOST}:{HTTPS_PORT}/login
```

Expect `{"status": "alive", ...}` and `200`. Otherwise use `refs/troubleshooting.md`.

### Phase 5 — First run (user)

Tell the user to open `https://{HOST}:{HTTPS_PORT}` (accept the self-signed certificate warning on LAN installs), create the first account and organisation, and store the **recovery phrase** offline. The agent must not see the recovery phrase or password.

### Phase 6 — Backups

```bash
./scripts/libreseal-backup.sh            # writes ./backups/libreseal-<timestamp>.dump (mode 600)
```

Explain that restoring needs the dump **and** the same `.env`, and that both must be stored securely and separately. Restore with `./scripts/libreseal-restore.sh --yes <file>` (replaces all data — only on explicit user request). Offer a daily cron entry:

```bash
(crontab -l 2>/dev/null; echo "30 3 * * * cd {WORKING_DIR} && ./scripts/libreseal-backup.sh >/dev/null") | crontab -
```

### Phase 7 — Let's Encrypt (optional, public domains only)

Follow `refs/docker-compose-deployment.md` → "Let's Encrypt": verify DNS, add the certbot service, switch nginx to the issued certificate, reload nginx and install the renewal cron job.

### Phase 8 — Hand-off to applications and agents

Do not use the user's own account for automation. Ask the user to create, in the UI (Access → Service Accounts), a service account restricted to the apps/environments needed and generate a token. Continue with the `libreseal-usage` skill for CLI setup and safe usage.

## Upgrading LibreSeal

```bash
./scripts/libreseal-backup.sh
git pull                 # or check out a newer verified tag
docker compose up -d --build
```

Migrations run automatically (`migrations` service).

## Uninstalling

```bash
docker compose down        # keeps data in the libreseal-postgres-data volume
docker compose down -v     # DESTROYS all data — only on explicit request, after a backup
```
