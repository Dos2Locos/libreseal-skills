# Troubleshooting Guide

Common issues when deploying LibreSeal with Docker Compose, with a focus on Let's Encrypt certificate setup.

## ACME Challenge Fails (certbot can't get certificate)

**Symptom:** `docker compose run --rm certbot certonly ...` fails with an error like:

```
Challenge failed for domain secrets.example.com
http-01 challenge for secrets.example.com
Cleaning up challenges
Some challenges have failed.
```

**Cause:** Let's Encrypt couldn't reach the ACME challenge file on port 80 at `http://{domain}/.well-known/acme-challenge/`. Common reasons:

1. **DNS not pointing to this server** — The domain doesn't resolve to this machine's IP.
2. **Port 80 is blocked** — A firewall (UFW, iptables, cloud security group) is blocking inbound port 80.
3. **nginx not running or not serving ACME challenges** — The config patch wasn't applied or nginx didn't restart.
4. **nginx config not updated** — The `/.well-known/acme-challenge/` location block is missing.

**Diagnosis:**

```bash
# Check DNS
dig @8.8.8.8 {domain} +short

# Check server public IP
curl -s https://api.ipify.org

# Check port 80 is reachable from outside (run from a different machine or use an online tool)
curl -v http://{domain}/.well-known/acme-challenge/test

# Check nginx is running
docker compose ps nginx

# Check nginx config is loaded correctly
docker compose exec nginx nginx -t

# Check nginx logs for errors
docker compose logs nginx
```

**Fix:**
- Fix DNS if it doesn't point to this server
- Open port 80 in firewall: `ufw allow 80/tcp` or equivalent
- Verify `nginx/default.conf` has the ACME challenge location in the HTTP server block:
  ```nginx
  # fragment: inside the port 80 server block
  location /.well-known/acme-challenge/ {
      root /var/www/certbot;
  }
  ```
- Verify the certbot-webroot volume is mounted in nginx: `docker compose config` should show the volume

## nginx Won't Start After Config Change

**Symptom:** `docker compose up -d --build nginx` fails or nginx exits immediately.

**Diagnosis:**

```bash
docker compose logs nginx
docker compose exec nginx nginx -t
```

**Common causes:**

- **Syntax error in nginx config** — Check for missing semicolons, braces, or typos. Run `nginx -t` to see the exact line.
- **SSL cert file not found** — If the config references Let's Encrypt paths (`/etc/letsencrypt/live/...`) but certbot hasn't run yet, nginx will fail to start. Make sure the config still points to the self-signed cert (`/etc/nginx/ssl/nginx.crt`) until after certbot succeeds.
- **Port already in use** — Something else is running on port 80 or 443. Check: `ss -tlnp | grep -E ':80|:443'`

## nginx Starts but Returns Self-Signed Cert After Switching

**Symptom:** After updating the `ssl_certificate` lines to Let's Encrypt paths and running `nginx -s reload`, the browser still shows the self-signed cert.

**Cause:** The nginx container's `/etc/letsencrypt` mount may not have picked up the new certs, or the reload didn't complete cleanly.

**Fix:**

```bash
# Verify the cert file exists inside the nginx container
docker compose exec nginx ls /etc/letsencrypt/live/{domain}/

# Force a clean restart (brief connection interruption)
docker compose restart nginx

# Re-verify
echo | openssl s_client -connect {domain}:443 -servername {domain} 2>/dev/null \
  | openssl x509 -noout -issuer
```

## Certificate Expires / Auto-Renewal Not Working

**Symptom:** Certificate expired. Browser shows security warning.

**Diagnosis:**

```bash
# Check cron jobs
crontab -l

# Check current cert expiry
echo | openssl s_client -connect {domain}:443 -servername {domain} 2>/dev/null \
  | openssl x509 -noout -dates

# Test renewal manually (dry run)
docker compose run --rm certbot renew --dry-run
```

**Common causes:**

- Cron job wasn't installed, or was removed
- Working directory in the cron job is wrong (docker compose can't find `docker-compose.yml`)
- Port 80 was blocked at renewal time

**Fix:**

Force renew immediately:

```bash
cd {working_dir}
docker compose run --rm certbot renew --force-renewal
docker compose exec nginx nginx -s reload
```

Reinstall the cron job:

```bash
(crontab -l 2>/dev/null | grep -v certbot; echo "0 0,12 * * * cd {working_dir} && docker compose run --rm certbot renew --quiet && docker compose exec nginx nginx -s reload") | crontab -
```

## LibreSeal Container CrashLooping

**Symptom:** `docker compose ps` shows a LibreSeal container restarting repeatedly.

**Diagnosis:**

```bash
docker compose logs backend
docker compose logs frontend
docker compose logs worker
docker compose logs migrations
```

**Common causes:**

- **Missing or invalid `.env`** — `HOST`, `NEXTAUTH_SECRET`, `SECRET_KEY`, `SERVER_SECRET`, `DATABASE_PASSWORD` must all be set.
- **Database migration failure** — Check `docker compose logs migrations`. Often caused by a wrong `DATABASE_PASSWORD` or Postgres not yet healthy.
- **Invalid `HOST` value** — Must be just the domain (`secrets.example.com`), not `https://secrets.example.com`.
- **Invalid `PUBLIC_URL`** — Must be `https://HOST` or `https://HOST:HTTPS_PORT`, matching `HOST` and `HTTPS_PORT`.

## 502 Bad Gateway

**Symptom:** nginx returns 502 Bad Gateway.

**Cause:** The upstream service (frontend or backend) is not ready yet. On LibreSeal versions whose `nginx/default.conf` has no `resolver 127.0.0.11` line, nginx also keeps proxying to a stale container IP after the backend or frontend is recreated (e.g. after `docker compose up -d --build`); `docker compose restart nginx` fixes it, and current versions resolve upstreams at request time.

**Diagnosis:**

```bash
docker compose ps
docker compose logs backend
docker compose logs frontend
```

**Fix:** Wait for migrations to complete — the backend only starts after `libreseal-migrations` exits successfully. Check:

```bash
docker compose logs migrations
```

If migrations failed, fix the `.env` database credentials and re-run:

```bash
docker compose up migrations
```

## Let's Encrypt Rate Limits

**Symptom:** certbot fails with `Error: too many certificates already issued for...`

**Cause:** Let's Encrypt limits issuance to 5 duplicate certificates per domain per week.

**Fix:** Wait up to a week, or use a staging certificate to test:

```bash
docker compose run --rm certbot certonly \
  --webroot \
  --webroot-path=/var/www/certbot \
  --email {EMAIL} \
  --agree-tos \
  --no-eff-email \
  --staging \
  -d {DOMAIN}
```

Staging certs are not trusted by browsers but are useful for verifying the ACME flow works end-to-end. Remove the `--staging` flag once you're confident the flow works, then delete the staging cert and re-issue:

```bash
docker compose run --rm certbot delete --cert-name {DOMAIN}
# Then re-run without --staging
```

## Can't Connect to LibreSeal After DNS Change

**Symptom:** LibreSeal was working, then DNS was changed (e.g., moving to Cloudflare), and now it fails.

**Cause:** If Cloudflare proxy (orange cloud) is enabled but SSL mode isn't set to `Full (strict)`, Cloudflare will try to connect to the origin over plain HTTP and get rejected.

**Fix:**
- In Cloudflare dashboard: SSL/TLS → set to **Full (strict)**
- Or temporarily disable the Cloudflare proxy (grey cloud) to bypass it

## Disk Space — Certbot Accumulating Old Certs

**Symptom:** Disk usage growing on a server running for many months.

**Fix:** certbot keeps the last few cert versions by default. Clean up old ones:

```bash
docker compose run --rm certbot delete --cert-name {DOMAIN}
# Then re-issue a fresh cert
```

Or prune unused Docker volumes periodically:

```bash
docker volume prune
```

Be careful — `docker volume prune` removes ALL unused volumes, not just certbot's. Only run if you're sure no important data is in unnamed volumes.

## Port Already in Use

**Symptom:** `docker compose up` fails with `bind: address already in use` for port 80 or 443.

**Fix:** Another service owns the port. Pick free ports and update `.env` (`HTTP_PORT`, `HTTPS_PORT` and the port in `PUBLIC_URL`), then `docker compose up -d`. For a fresh install pass `--http-port`/`--https-port` to `scripts/libreseal-init.sh`.

## CLI Fails with a Certificate Error on a LAN Install

**Symptom:** `libreseal` reports an SSL error against the bundled self-signed certificate.

**Fix:** Prefer a trusted certificate (Let's Encrypt or your own CA mounted into nginx). For local testing only, `export LIBRESEAL_VERIFY_SSL=False`.

## Access Denied: Network Access Policies

**Symptom:** API calls return 403 "Access denied: a network access policy restricts access from your IP address", or the UI/GraphQL reports "Your IP address is not allowed to access {ORG}". Token issuance through AWS IAM / Azure Entra identities returns the same 403.

**Cause:** A network access policy (Access Control → Network) applies to the account — its own or an organisation-global one — and the client IP is not in any of its IPs/CIDRs. Common reasons:

- The client really is outside the allowed ranges (VPN off, new public IP).
- **Another reverse proxy sits in front of the bundled nginx** (Traefik, Caddy, Cloudflare Tunnel…), so every request appears to come from that proxy.
- The backend is reached without the bundled nginx and `TRUSTED_PROXY_CIDRS` does not include the proxy that sets `X-Real-IP`/`X-Forwarded-For`.

**Diagnosis:** the bundled nginx logs the client IP it resolved as the first field of each access-log line:

```bash
docker compose logs --tail 20 nginx
```

**Fix:**

- Outer proxy: set in `.env` the proxy addresses and header, then `docker compose up -d nginx`:
  ```bash
  NGINX_REAL_IP_FROM=172.18.0.10            # your proxy IPs/CIDRs, comma-separated (never 0.0.0.0/0)
  NGINX_REAL_IP_HEADER=X-Forwarded-For      # Cloudflare: CF-Connecting-IP
  ```
- Outside the bundled Compose setup, set `TRUSTED_PROXY_CIDRS` to the address of the proxy in front of the backend.
- Wrong policy or locked out (operator, on the host):
  ```bash
  docker compose exec backend python manage.py libreseal_clear_network_policies                          # list
  docker compose exec backend python manage.py libreseal_clear_network_policies --organisation {ORG} --yes # delete
  ```
  Deletions are recorded in the organisation's audit log.

Servers from before network policies were enforced report "network access policies apply to this account but LibreSeal cannot enforce them"; the same command clears them.

## Dynamic or Rotating Secrets Migrated from Phase

**Symptom:** `libreseal run`/`secrets export` fails with "HTTP 501: The dynamic secrets feature is not available in LibreSeal…", or deleting an app, environment or folder is refused because it "contains dynamic or rotating secrets with live provider credentials migrated from Phase".

**Cause:** The database came from Phase with dynamic or rotating secrets. LibreSeal cannot serve them nor revoke their credentials at the provider, so it fails explicitly instead of dropping them silently.

**Fix (operator):**

```bash
docker compose exec backend python manage.py libreseal_remove_legacy_credentials              # list
docker compose exec backend python manage.py libreseal_remove_legacy_credentials --yes        # remove those without live credentials
# After revoking the remaining credentials at the provider (AWS, database…):
docker compose exec backend python manage.py libreseal_remove_legacy_credentials --yes --credentials-revoked
```

