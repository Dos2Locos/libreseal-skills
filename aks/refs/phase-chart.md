# Phase Helm chart contract

Use this reference to discover the current chart, generate secrets and minimal values, render safely, install, and verify Phase.

## Contents

- [Sources of truth](#sources-of-truth)
- [Discover and pin](#discover-and-pin)
- [Current minimum Secret](#current-minimum-secret)
- [Authentication posture](#authentication-posture)
- [Enterprise license](#enterprise-license)
- [Minimal bundled-data values](#minimal-bundled-data-values)
- [External or mixed data values](#external-or-mixed-data-values)
- [Host and routing contract](#host-and-routing-contract)
- [Render and inspect](#render-and-inspect)
- [Install and hook caveat](#install-and-hook-caveat)
- [Verification](#verification)
- [Upgrade and rollback checkpoint](#upgrade-and-rollback-checkpoint)

## Sources of truth

- Published repository: https://helm.phase.dev
- Chart source and values: https://github.com/phasehq/kubernetes-secrets-operator/tree/main/phase-console
- Self-hosting configuration: https://docs.phase.dev/self-hosting/configuration/envars
- OAuth SSO: https://docs.phase.dev/access-control/authentication/oauth-sso
- Organisation SSO: https://docs.phase.dev/access-control/authentication/sso
- Platform integrations: https://docs.phase.dev/integrations/platforms

Treat the published chart selected for the deployment as authoritative. The observations labeled `1.0.2` below explain a tested release and must be revalidated for later versions.
For SSO or third-party integrations, re-open both Phase's page and the provider's official page so callback URLs and scopes match the final hostname and current release. Use a documented `.md` page or `Accept: text/markdown` when the docs site supports it; otherwise use the rendered page. Never guess these values.

## Discover and pin

```bash
helm repo add phase https://helm.phase.dev
helm repo update phase
helm search repo phase/phase --versions
helm show chart phase/phase --version <chart-version>
helm show values phase/phase --version <chart-version> > phase-chart-values.reference.yaml
```

Select an immutable chart version. Unless the user requests a specific Console version, resolve the latest stable published Phase release from GitHub once:

```bash
PHASE_VERSION="$(
  curl --fail --silent --show-error --location \
    --header 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/phasehq/console/releases/latest |
  jq -er '
    select(.draft == false and .prerelease == false)
    | .tag_name
    | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
  '
)"

printf 'Pinned Phase Console version: %s\n' "$PHASE_VERSION"
```

Stop if the request or validation fails; never fall back to `latest`. Keep this resolved value unchanged throughout the deployment and record it in the journal. Set the literal tag in `global.version` and also pass `--set-string global.version="$PHASE_VERSION"` to every render/install command so the chart cannot fall back to its `latest` default.

The GitHub release tag is consumed verbatim by chart `1.0.2`, producing `docker.io/phasehq/frontend:<tag>` and `docker.io/phasehq/backend:<tag>`. If Docker is available, verify both manifests before deployment:

```bash
docker manifest inspect "docker.io/phasehq/frontend:$PHASE_VERSION" >/dev/null
docker manifest inspect "docker.io/phasehq/backend:$PHASE_VERSION" >/dev/null
```

For chart `1.0.2`, use release name `phase-console`. Its default database/Redis hosts use `.Release.Name`, while the Services use the chart fullname; release names that do not contain `phase` can mismatch.

## Current minimum Secret

Chart `1.0.2` needs these four values for the minimal password-auth deployment:

- `SECRET_KEY`
- `SERVER_SECRET`
- `DATABASE_PASSWORD`
- `REDIS_PASSWORD`

It lists `NEXTAUTH_SECRET` as optional, but the current Console does not require it. Re-check the selected chart and image before omitting or adding keys.

Have the user run this command outside the AI context for a new bundled-data deployment:

```bash
kubectl create namespace phase --dry-run=client -o yaml | kubectl apply -f -

kubectl -n phase create secret generic phase-console-secret \
  --from-literal=SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=SERVER_SECRET="$(openssl rand -hex 32)" \
  --from-literal=DATABASE_PASSWORD="$(openssl rand -hex 32)" \
  --from-literal=REDIS_PASSWORD="$(openssl rand -hex 32)"
```

If the Secret exists, stop. Do not recreate it. For external services, replace only the relevant generated password with an interactive shell variable, never a chat value:

```bash
read -rsp "PostgreSQL password: " PHASE_DATABASE_PASSWORD; echo
read -rsp "Redis password: " PHASE_REDIS_PASSWORD; echo

kubectl -n phase create secret generic phase-console-secret \
  --from-literal=SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=SERVER_SECRET="$(openssl rand -hex 32)" \
  --from-literal=DATABASE_PASSWORD="$PHASE_DATABASE_PASSWORD" \
  --from-literal=REDIS_PASSWORD="$PHASE_REDIS_PASSWORD"

unset PHASE_DATABASE_PASSWORD PHASE_REDIS_PASSWORD
```

Build one final user-side command for the selected topology. Add optional SSO, SMTP, integration, and license keys to that creation command only after confirming their exact names in the selected chart and current Phase environment-variable documentation. Prompt for each sensitive value with `read -rsp`, use it without printing it, then `unset` it.

Verify key names without reading values:

```bash
kubectl -n phase get secret phase-console-secret -o json | jq -r '.data | keys[]'
```

Store a recoverable copy in the customer's approved secret-management/backup system. `SERVER_SECRET` must remain stable with the database; losing it can make encrypted Phase data unreadable.

Optional chart `1.0.2` names include `SMTP_PASSWORD` (not the old `EMAIL_HOST_PASSWORD`), provider-specific client IDs/secrets, `AWS_INTEGRATION_ACCESS_KEY_ID`, and `AWS_INTEGRATION_SECRET_ACCESS_KEY`. Use only names present in the selected chart.

## Authentication posture

- `passwordAuth.enabled: true` is valid without SSO.
- `sso.providers: ""` is valid; instance-level SSO is not required.
- Without SMTP, password registrations become active immediately. Keep ingress private or source-restricted during onboarding.
- To move to SSO-only, configure and test SSO with password auth still enabled, create/recover an administrator in a fresh private session, then disable password auth and test again.
- Treat SSO, SMTP, integration, and license values as sensitive user-side inputs.

## Enterprise license

Phase self-hosted Enterprise uses `PHASE_LICENSE_OFFLINE`. If the user does not have a license, finish the Community deployment and provide the current official trial/license request path; do not invent or block on a commercial workflow.

Have the user add the license locally while creating `phase-console-secret`:

```bash
read -rsp "Phase offline license: " PHASE_LICENSE_OFFLINE; echo

# Include this line in the same kubectl create secret command:
--from-literal=PHASE_LICENSE_OFFLINE="$PHASE_LICENSE_OFFLINE"

unset PHASE_LICENSE_OFFLINE
```

Do not set the chart's plain `license.offline` value because Helm values and release metadata are not a secret store.

Chart `1.0.2` supports generic secret-file mounts through the `secrets.backend` and `secrets.worker` key lists. For a licensed deployment:

1. Read those arrays from the selected chart values.
2. Copy every existing entry into the overlay and append `PHASE_LICENSE_OFFLINE` to both arrays. Helm replaces lists; a one-item override would silently remove the default secret mounts.
3. Render and confirm backend and worker receive `PHASE_LICENSE_OFFLINE_FILE` pointing under `/etc/phase/secrets/`, with the file sourced from `phase-console-secret`.
4. Verify license success without printing the license or identity-bearing validation details:

```bash
kubectl -n phase logs deployment/phase-console-backend --tail=200 |
rg -q 'License is valid\.'
```

Treat a zero exit status as success. If the selected chart no longer has this generic secret mechanism, stop and derive a secret-backed alternative from that chart; never fall back to a plaintext Helm value.

## Minimal bundled-data values

Merge the ingress block from `networking.md` or `tailscale.md` into this base:

```yaml
global:
  host: "<final-hostname>"
  httpProtocol: "https://"
  version: "<pinned-console-version>"

phaseSecrets: phase-console-secret

passwordAuth:
  enabled: true

sso:
  providers: ""

database:
  external: false
  name: phase
  user: phase
  persistence:
    enabled: true
    size: 50Gi
    storageClass: "<default-or-selected-storage-class>"

redis:
  external: false
```

Bundled PostgreSQL is one StatefulSet replica on a 50 GiB `ReadWriteOnce` PVC. Bundled Redis is one Deployment replica with no persistence. Neither includes replication, automated backups, or failover. Use this topology for dev/test unless the user explicitly accepts the production risk.

## External or mixed data values

PostgreSQL and Redis are independent switches. External PostgreSQL with bundled Redis is valid, as is the reverse.

```yaml
database:
  external: true
  host: "<postgres-fqdn>"
  port: "5432"
  name: "phase"
  user: "<phase-database-user>"
  sslmode: "require"
  ssl: true

redis:
  external: true
  host: "<redis-fqdn>"
  port: "<tls-port>"
  ssl: true
  user: "<redis-user-if-required>"
```

For chart `1.0.2`, set both PostgreSQL flags: `sslmode` controls `psql` init containers and `ssl` controls the Django application. A custom CA path value exists, but the chart does not mount arbitrary CA bundles; use a publicly trusted or already-installed CA, or treat custom CA mounting as chart work.

Test DNS and TCP/TLS connectivity from an AKS pod before installing Phase. See `data-services.md`.

## Resource baseline

Chart `1.0.2` steady requests with bundled services are approximately:

| Component | CPU | Memory |
|---|---:|---:|
| Frontend | 250m | 512Mi |
| Backend | 500m | 512Mi |
| Worker | 500m | 512Mi |
| PostgreSQL | 500m | 1Gi |
| Redis | 50m | 128Mi |
| Total | 1.8 CPU | 2.625Gi |

The migration Job temporarily adds about 100m CPU and 256Mi. Kubernetes system pods, Azure/Cilium daemonsets, ingress, Tailscale, rollout surge, and allocatable-node overhead are additional. Production replica counts require a new scheduling calculation.

## Host and routing contract

Set the final hostname before installation:

```yaml
global:
  host: "<final-hostname>"

ingress:
  host: "<final-hostname>"
```

`global.host` drives frontend URLs, allowed hosts/origins, cookies, and OAuth redirects. `ingress.host` drives only the chart-managed Ingress.

Chart `1.0.2` generates NGINX regex/rewrite annotations. Current Phase backend code accepts `/service/...` directly. For a custom controller, set `ingress.enabled: false` and route:

- `/service` with `Prefix` to `phase-console-backend:8000`
- `/` with `Prefix` to `phase-console-frontend:3000`

Do not rewrite `/service`.

## Render and inspect

```bash
chart_dir="$(mktemp -d)"
helm pull phase/phase --version <chart-version> --untar --untardir "$chart_dir"
helm lint "$chart_dir/phase" --values phase-values.yaml \
  --set-string global.version="$PHASE_VERSION"

helm template phase-console phase/phase \
  --version <chart-version> \
  --namespace phase \
  --values phase-values.yaml \
  --set-string global.version="$PHASE_VERSION" > phase-rendered.yaml

kubectl apply --dry-run=server -f phase-rendered.yaml >/dev/null
```

Inspect before applying:

```bash
rg -n 'latest|invalid|localhost|LoadBalancer|hook:|secretKeyRef:|storageClassName:|ingressClassName:' phase-rendered.yaml
```

Confirm:

- every image is pinned;
- the final hostname is consistent;
- no unexpected public `LoadBalancer` exists;
- secret references use the intended Secret;
- the database host/service names match the release;
- external PostgreSQL/Redis omit bundled workloads and use TLS;
- storage class and PVC size are correct;
- migration hook ordering is understood.

## Install and hook caveat

```bash
helm upgrade --install phase-console phase/phase \
  --version <chart-version> \
  --namespace phase \
  --values phase-values.yaml \
  --set-string global.version="$PHASE_VERSION" \
  --timeout 15m
```

In chart `1.0.2`, application init containers wait for migrations while migrations are a `post-install,post-upgrade` hook. `--wait` or `--atomic` can create a circular wait, so omit them for that rendered layout. Reassess later chart versions.

The successful hook deletes its Job. No migration Job after install can be normal. Use Helm status, events, database migration state, and application health as evidence.

## Verification

```bash
helm -n phase status phase-console
helm -n phase get values phase-console --all
kubectl -n phase get pods,pvc,services,ingress -o wide
kubectl -n phase get events --sort-by=.lastTimestamp | tail -n 40
kubectl -n phase rollout status deployment/phase-console-frontend --timeout=10m
kubectl -n phase rollout status deployment/phase-console-backend --timeout=10m
kubectl -n phase rollout status deployment/phase-console-worker --timeout=10m
kubectl -n phase get deployment \
  phase-console-frontend phase-console-backend phase-console-worker \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'
curl --fail --show-error "https://<final-hostname>/api/health"
curl --fail --show-error "https://<final-hostname>/service/health/"
```

Confirm every Phase frontend/backend image line uses the exact resolved `$PHASE_VERSION`; Ready pods then prove Kubernetes successfully pulled that tag.

Chart `1.0.2` lacks ConfigMap/Secret checksums on application pod templates. After host, auth, SMTP, or other relevant config changes:

```bash
kubectl -n phase rollout restart \
  deployment/phase-console-frontend \
  deployment/phase-console-backend \
  deployment/phase-console-worker
```

Then verify live environments use the final host. Never print secret environment variables.

## Upgrade and rollback checkpoint

Before upgrading:

1. Read chart release notes and render the diff.
2. Back up PostgreSQL and the Phase Secret through approved systems.
3. Confirm available node and quota surge capacity.
4. Record the current chart/image versions and `helm get values` output.
5. Test migration and restore in a non-production environment.

Use `helm rollback` only after determining whether the database migration is backward compatible. Helm rollback alone does not reverse data migrations or restore PVC/database contents.
