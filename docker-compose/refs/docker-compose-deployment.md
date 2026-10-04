# Docker Compose Deployment Reference (LibreSeal)

Reference for deploying LibreSeal from `https://github.com/Dos2Locos/libreseal` with Docker Compose, plus optional Let's Encrypt TLS.

## Architecture

```
Clients (browser, libreseal CLI, apps)
    │
    ▼
 nginx :HTTP_PORT/:HTTPS_PORT            (libreseal-nginx)
    ├── /service/ → backend:8000 (Django API, libreseal-backend)
    └── /         → frontend:3000 (Next.js, libreseal-frontend)
         │
    ┌────┴─────┐
 Postgres    Redis        (+ worker, + one-shot migrations)
```

Data lives in the named volume `libreseal-postgres-data`.

## `.env` produced by `scripts/libreseal-init.sh`

| Variable | Meaning |
|---|---|
| `HOST` | Bare hostname (no scheme/port). Used for `ALLOWED_HOSTS` and the session cookie domain |
| `PUBLIC_URL` | `https://HOST[:HTTPS_PORT]` — the URL users and the CLI use |
| `HTTP_PORT`, `HTTPS_PORT` | Host ports published by nginx |
| `NEXTAUTH_SECRET`, `SECRET_KEY`, `SERVER_SECRET`, `DATABASE_PASSWORD` | Random 32-byte hex values generated per install. **Never print or share.** `SERVER_SECRET` is required to read server-side encrypted data after a restore |
| `ENABLE_PASSWORD_AUTH` | `true` by default |
| `SSO_PROVIDERS` | Optional, comma-separated: `google`, `github`, `gitlab`, `authentik`, `authelia` |

To move to another hostname or port later, the user edits `HOST`, `PUBLIC_URL`, `HTTP_PORT`, `HTTPS_PORT` in `.env` and runs `docker compose up -d`.

## OAuth / OIDC callback URLs

Pattern: `{PUBLIC_URL}/api/auth/callback/{provider}`

| Provider | `SSO_PROVIDERS` value | Extra variables |
|---|---|---|
| Google | `google` | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` |
| GitHub | `github` | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` |
| GitLab | `gitlab` | `GITLAB_CLIENT_ID`, `GITLAB_CLIENT_SECRET` (`GITLAB_AUTH_URL` for self-hosted GitLab) |
| Authentik | `authentik` | `AUTHENTIK_URL`, `AUTHENTIK_APP_SLUG`, `AUTHENTIK_CLIENT_ID`, `AUTHENTIK_CLIENT_SECRET` |
| Authelia | `authelia` | `AUTHELIA_URL`, `AUTHELIA_CLIENT_ID`, `AUTHELIA_CLIENT_SECRET` |

Only the user edits these values in `.env`.

## Health checks

```bash
curl -ksS {PUBLIC_URL}/service/health/      # {"status": "alive", "version": "..."}
curl -ks -o /dev/null -w '%{http_code}\n' {PUBLIC_URL}/login
docker compose ps
```

## Backup and restore

```bash
./scripts/libreseal-backup.sh [OUTPUT_DIR]          # pg_dump custom format, mode 600, verified with pg_restore --list
./scripts/libreseal-restore.sh --yes FILE           # stops app services, pg_restore --clean, starts everything
```

A restore only works with the same `.env` secrets. Users still need their own password or recovery phrase to decrypt secrets.

## Let's Encrypt

Requires a public domain whose A/AAAA record points at this server and port 80 reachable from the Internet (`HTTP_PORT=80`).

### 1. Verify DNS

```bash
curl -s https://api.ipify.org            # server public IP
dig @1.1.1.1 {DOMAIN} +short
dig @8.8.8.8 {DOMAIN} +short
dig @9.9.9.9 {DOMAIN} +short
```

Proceed only when all resolvers return the server IP.

### 2. Add certbot to `docker-compose.yml`

Add to the `nginx` service `volumes`:

```yaml
      - certbot-webroot:/var/www/certbot:ro
      - certbot-certs:/etc/letsencrypt:ro
```

Add the service:

```yaml
  certbot:
    container_name: libreseal-certbot
    image: certbot/certbot:latest
    volumes:
      - certbot-webroot:/var/www/certbot
      - certbot-certs:/etc/letsencrypt
```

Add to the top-level `volumes`:

```yaml
  certbot-webroot:
  certbot-certs:
```

### 3. nginx config with ACME challenge

Replace `nginx/default.conf` with:

```nginx
server {
    listen 80;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_tokens off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+AESGCM:EECDH+CHACHA20;
    ssl_prefer_server_ciphers on;

    # Initially the self-signed certificate baked into the nginx image.
    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    location /service/ {
        rewrite ^/service/(.*) /$1 break;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $http_host;
        proxy_set_header X-NginX-Proxy true;
        proxy_pass http://backend:8000;
        proxy_redirect off;
        proxy_cookie_path / "/; HttpOnly; SameSite=strict";
        proxy_buffers 16 32k;
        proxy_buffer_size 64k;
        proxy_busy_buffers_size 128k;
    }

    location / {
        include /etc/nginx/mime.types;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $http_host;
        proxy_set_header X-NginX-Proxy true;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://frontend:3000;
        proxy_redirect off;
        proxy_buffers 16 32k;
        proxy_buffer_size 64k;
        proxy_busy_buffers_size 128k;
    }
}
```

```bash
docker compose up -d nginx
```

### 4. Issue the certificate

```bash
docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot \
  --email {EMAIL} --agree-tos --no-eff-email -d {DOMAIN}
```

### 5. Switch nginx to the certificate

```nginx
    ssl_certificate /etc/letsencrypt/live/{DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{DOMAIN}/privkey.pem;
```

```bash
docker compose exec nginx nginx -s reload
echo | openssl s_client -connect {DOMAIN}:443 -servername {DOMAIN} 2>/dev/null | openssl x509 -noout -issuer -dates
```

### 6. Renewal

```bash
(crontab -l 2>/dev/null; echo "0 0,12 * * * cd {WORKING_DIR} && docker compose run --rm certbot renew --quiet && docker compose exec nginx nginx -s reload") | crontab -
```

## Upgrading

```bash
./scripts/libreseal-backup.sh
git pull
docker compose up -d --build
```

## Cloudflare

With Cloudflare proxying, use SSL/TLS mode **Full (strict)** and forward the real client IP by enabling the commented `map $http_cf_connecting_ip` block in `nginx/default.conf` and using `$client_real_ip` in `X-Real-IP`.
