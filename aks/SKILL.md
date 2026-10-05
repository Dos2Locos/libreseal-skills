---
name: aks
description: Interview a customer, plan, deploy, and operate Phase Console on Microsoft Azure Kubernetes Service (AKS) from an empty subscription or an existing cluster. Use for Azure/AKS architecture, regional VM SKU and quota preflight, cluster creation, Helm installation or upgrades, public or private ingress, Tailscale ingress/Funnel/egress, internal or Azure-managed PostgreSQL and Redis, Phase licensing, Azure Key Vault integration, deployment validation, and recovery from AKS capacity, scheduling, networking, or migration failures.
---

# Deploy Phase on Azure AKS

> **Not adapted to LibreSeal.** This is the upstream Phase guide, kept for reference. It deploys Phase images and Helm charts, not LibreSeal. Use the `docker-compose` skill instead.


Act as a Phase forward-deployed engineer. Take the deployment from discovery to a tested handoff while letting the user choose the security, availability, networking, and data topology.

## Operating rules

- Perform read-only discovery immediately. Run safe, in-scope commands and create non-secret manifests without asking at every step.
- Before creating billable Azure resources, show one concise architecture/cost-bearing resource summary and get confirmation.
- Determine which systems the current session can change: Azure subscription, AKS cluster, DNS, identity provider, Tailscale policy, external databases, and secret manager. For anything inaccessible, produce the exact minimal command, manifest, or policy merge for the user or responsible administrator and pause at that dependency.
- Make manual handoffs brief but explanatory. Use four labels: **Why** (what this unlocks), **Open** (a direct official console link), **Do** (exact clicks/fields and what default state may already exist), and **Confirm** (the non-secret success signal to return). Mention a meaningful alternative or security tradeoff when one exists.
- When the user supplies an existing policy or configuration, return a complete merged artifact plus a short list of changed sections. Never make them infer insertion points or replace unrelated policy.
- Never ask for, print, decode, or inspect secret values. Give the user a short editable command to run in their own terminal; verify only that the Secret and expected key names exist.
- Do not put credentials in Helm values, shell history examples, Git, tickets, deployment journals, or chat. Treat license keys as sensitive too.
- Preserve `SERVER_SECRET` with database backups. Never rotate or recreate an existing Phase Secret casually.
- Auto-detect the active Azure subscription. Ask the user to choose only when the active subscription is wrong or ambiguous.
- For a new install, resolve the latest stable Phase Console GitHub release once, validate its tag, and pin that exact tag for the whole deployment. Honor an explicitly requested version. Pin the chart, Tailscale operator, and other components separately; never deploy `latest`.
- Establish the final hostname and ingress path before installing Phase. Never deploy with a placeholder host and repair it later.
- Track every explicit choice with one of: `selected`, `prepared`, `enabled`, `verified`, or `deferred`. State why and the next gate for anything deferred; never silently omit a selected feature such as Funnel.
- Prefer current official Phase and provider documentation. Treat a local source checkout as supplemental, because it may not exist in another environment. Use a documented raw-Markdown endpoint or `Accept: text/markdown` when supported. Never guess callback URLs, scopes, or portal paths.
- Keep a redacted deployment journal: command or manifest, outcome, failure, diagnosis, resolution, and any deviation from the chosen design.
- Do not delete a cluster, resource group, database, PVC, public IP, or tailnet device without explicit confirmation and an exact inventory of what will be lost.
- Do not edit AKS-managed resources in the `MC_*` node resource group to work around reconciliation failures.

## Load references deliberately

Read these files before acting in the corresponding area:

- Always read `refs/preflight-and-capacity.md` and `refs/phase-chart.md`.
- Read `refs/networking.md` for Azure application routing, public ingress, private ingress, or a bring-your-own controller.
- Read `refs/data-services.md` when choosing or provisioning PostgreSQL or Redis.
- Read `refs/tailscale.md` when Tailscale ingress, Funnel, API access, or tailnet egress is requested.
- Read `refs/azure-integrations.md` when Azure Key Vault sync or Azure external identities are requested.
- Read `refs/troubleshooting.md` before changing infrastructure in response to a failure.

Re-open the official links in those references for version-sensitive commands and limitations.

## Workflow

### 1. Discover the environment

Check `az`, `kubectl`, `kubelogin`, `helm`, `jq`, `curl`, and `openssl`. If Azure authentication is missing, ask the user to run `az login` or their organization-specific login flow outside the agent, then continue.

Display the active identity and subscription without hard-coding an ID:

```bash
az account show --query '{name:name,id:id,tenantId:tenantId,user:user.name}' -o yaml
```

For an existing cluster, obtain credentials and prove the active context before doing anything else:

```bash
az aks get-credentials --resource-group <resource-group> --name <cluster> --overwrite-existing
kubectl config current-context
kubectl cluster-info
kubectl get nodes -o wide
```

If `kubelogin` is missing, tell the user to run `az aks install-cli`; do not downgrade to admin credentials as a shortcut.

Once the intended region and node SKU are known, follow the Markdown-only regional/SKU/quota checks in `refs/preflight-and-capacity.md`. If they are not known yet, collect them in step 2 and then return to the checks. Run the listed read-only Azure CLI commands individually. Use one target region first. Scan alternatives only after it fails eligibility or quota; quota and SKU visibility do not guarantee live physical capacity.

Inspect an existing AKS cluster, ingress inventory, storage, and scheduling posture. Distinguish AKS pricing tier, AKS Automatic, and node auto-provisioning; they are different concepts.

Inspect the live Phase chart rather than copying old values:

```bash
helm repo add phase https://helm.phase.dev
helm repo update phase
helm search repo phase/phase --versions
helm show chart phase/phase --version <chart-version>
helm show values phase/phase --version <chart-version> > phase-chart-values.reference.yaml
```

Resolve the default Console version with the GitHub API command in `refs/phase-chart.md`. Keep the resulting `PHASE_VERSION` unchanged through render, install, and verification; do not query “latest” again mid-deployment.

Use a local Phase chart checkout as an additional source when available, but deploy the selected published chart unless the user explicitly requests a development build.

### 2. Collect choices once

Ask one compact set of questions, omitting facts already discovered:

1. Azure target: active subscription/tenant, new or existing AKS, dev/test or production, region, resource group, naming constraints, and any required cluster/node SKU or autoscaling policy.
2. Exposure: public Azure ingress, private Tailscale, Tailscale plus Funnel, or an existing controller. Collect the final hostname/DNS owner and whether Funnel may expose the whole hostname or only approved API/SCIM paths.
3. PostgreSQL: bundled, existing external, or new Azure Database for PostgreSQL.
4. Redis: bundled, existing external, or new Azure Managed Redis. Choose independently from PostgreSQL.
5. Authentication: initial administrator path, password onboarding, SSO provider, SMTP-backed password registration, and registration/domain restrictions. Instance-level SSO is optional.
6. Phase license: Community or Enterprise; if Enterprise, whether the user already has an offline self-hosted license. Never request the license value in chat.
7. Tailscale: tailnet administrator availability, standalone or HA target, intended users/groups, and each required egress destination, port, protocol, TLS expectation, and non-secret health endpoint.
8. Required integrations: Azure Key Vault, Azure external identities, monitoring, backups, private DNS, or customer-managed secret injection.
9. Availability target, recovery objectives, maintenance window, expected load, and cost constraints.

After the answers, list only the remaining access or credential handoffs using the **Why / Open / Do / Confirm** format. Ask the user to authenticate interactively in their own terminal or have the responsible administrator apply the generated change; never ask them to paste a credential.

Defaults when the user has no preference:

- Use an AKS Standard-provisioned cluster with a normal system node pool for the predictable from-zero path, not AKS Automatic.
- Use bundled PostgreSQL and Redis only for dev/test. Recommend managed services and tested backup/restore for production.
- Keep onboarding private or source-restricted. Do not enable Funnel or remove a bootstrap allowlist until authentication is tested.
- For a new production public ingress, prefer a currently supported Gateway API or customer-standard controller. Treat managed NGINX as a time-bounded compatibility path and re-check Microsoft's support date before selecting it.
- Use the release name `phase-console` unless the inspected chart proves arbitrary release names are safe.

### 3. Present the architecture checkpoint

Summarize:

- subscription, region, resource group, cluster profile, node SKU/count/autoscaling, and quota headroom;
- ingress path and final hostname ownership;
- PostgreSQL and Redis placement, encryption, persistence, HA, and backups;
- public exposure and authentication boundary;
- Tailscale standalone versus ProxyGroup availability;
- who must apply DNS, IdP, Tailscale policy, license, or secret-manager changes;
- pinned versions and all billable resources.

Include a compact selected-feature status list. Repeat the chosen exposure mode explicitly; for example, record Funnel as `selected` and later `deferred pending private authentication`, rather than letting it disappear from the plan.

Obtain confirmation before provisioning a new cluster or managed data service. Existing explicit authorization to build the stated environment is enough; do not repeatedly reconfirm normal Kubernetes resources.

### 4. Prepare AKS and ingress

For a new cluster, follow `refs/preflight-and-capacity.md` and `refs/networking.md`. Prefer Azure CNI Overlay, managed identity, OIDC, workload identity, and an explicit autoscaling range. Preserve upgrade/surge quota headroom.

For an AKS Automatic cluster that actually has the older managed external NGINX controller, do not change it from `External` to `Internal`. A tested failure mode deletes the load balancer that node auto-provisioning still references. Newer Automatic clusters may use Gateway API instead, so inspect live `GatewayClass`, `IngressClass`, and `ingressProfile` state. Preserve the existing managed path and add a separate reviewed private controller/gateway, or rebuild as a Standard-provisioned cluster.

Prepare ingress before Phase:

- Public Azure: create or select a currently supported controller/Gateway, obtain its address, configure DNS/TLS, and keep a trusted bootstrap source restriction. If the chosen implementation cannot enforce that restriction, do not publish the route until authentication is ready.
- Private Tailscale/Funnel: install the operator, create the private bridge, wait for the `.ts.net` hostname, then use that exact hostname in Phase values. If Funnel was selected, mark it explicitly as deferred until private authentication succeeds, then enable and verify it rather than silently stopping at private ingress.
- Bring your own controller: disable chart ingress and route `/service` to the backend and `/` to the frontend without rewriting `/service`.

### 5. Create the namespace and user-side Secret

Create the namespace yourself. If the Secret does not exist, print the current-chart command from `refs/phase-chart.md` for the user to run. Substitute external database/Redis passwords, an optional `PHASE_LICENSE_OFFLINE`, or provider credentials only inside that user-run command.

Pause until the user confirms success, then verify names only:

```bash
kubectl -n phase get secret phase-console-secret -o json | jq -r '.data | keys[]'
```

Never retrieve or decode `.data` values.

### 6. Generate and validate minimal values

Build a small overlay from the inspected chart. Pin the Console image and set the final host in every host field the selected chart uses. Configure PostgreSQL and Redis independently. If an Enterprise license is selected, mount `PHASE_LICENSE_OFFLINE` from the Kubernetes Secret using the selected chart's secret-file mechanism; never place the license value in Helm values. Avoid copying the chart's full defaults.

Before installation, pull the selected chart to a temporary directory for linting, then render the repository chart:

```bash
chart_dir="$(mktemp -d)"
helm pull phase/phase --version <chart-version> --untar --untardir "$chart_dir"
helm lint "$chart_dir/phase" --values phase-values.yaml --set-string global.version="$PHASE_VERSION"
helm template phase-console phase/phase --version <chart-version> --namespace phase \
  --values phase-values.yaml --set-string global.version="$PHASE_VERSION" > phase-rendered.yaml
kubectl apply --dry-run=server -f phase-rendered.yaml >/dev/null
```

Inspect the rendered Ingress, Services, migration hooks, secret references, resource requests, storage class, and image tags. Abort if a placeholder hostname, mutable `latest`, unexpected public LoadBalancer, or missing external-service TLS setting remains.

### 7. Install Phase

Use a rerunnable install:

```bash
helm upgrade --install phase-console phase/phase \
  --version <chart-version> \
  --namespace phase \
  --values phase-values.yaml \
  --set-string global.version="$PHASE_VERSION" \
  --timeout 15m
```

Add `--wait` or `--atomic` only after inspecting hook ordering. Chart `1.0.2` can deadlock because application init containers wait for a post-install migration hook; omit both for that layout.

Watch events and workloads. Do not assume an absent migration Job failed: successful hooks may delete themselves.

### 8. Verify end to end

Verify all applicable checks:

- Helm status and pinned image tags.
- Pods, rollouts, Services, Ingress, PVC binding, storage class, and recent events.
- Frontend `/api/health` and backend `/service/health/` through the final ingress.
- Host, origins, cookies, and frontend API base use the final hostname.
- Database migration and read/write persistence; Redis connectivity.
- Enterprise license validity when selected, without displaying the license or identity-bearing validation details.
- Restart or node-drain behavior appropriate to the availability target.
- Authentication in a fresh private browser session before widening access.
- New private and, when Funnel is selected, public audit events record the intended client address, not an ingress proxy pod IP.
- Every required backend and worker replica can reach each destination-specific Tailscale egress route while the application retains the TLS certificate identity hostname.

If the chart lacks ConfigMap/Secret checksum annotations, explicitly restart frontend, backend, and worker after relevant configuration changes and verify their live environments.

### 9. Harden and hand off

For production, close bootstrap access, enforce the selected authentication policy, back up the Phase Secret in an approved system, test database restore, configure monitoring/alerts, validate upgrades, and document availability boundaries. Do not claim HA merely because application replicas scale; ingress proxies, databases, Redis, storage, and external targets each need their own redundancy.

Provide the user with:

- final URL and exposure mode;
- exact pinned versions and resource inventory;
- redacted commands/manifests and deployment journal;
- verification results and known limitations;
- backup/restore, upgrade, and rollback commands;
- any manual portal, DNS, Tailscale policy, or secret steps still required.

When the core deployment is healthy, offer one short prioritized follow-up list rather than expanding scope automatically: client-IP verification on every exposure path, SMTP/email notifications, SSO, backup/restore, and monitoring/alerts.

## Completion criteria

Finish only when Phase is reachable through the selected final path, both health routes pass, workloads and storage are healthy, authentication and client-IP behavior match the design, external data/tailnet connections are tested where selected, and the user has a safe operational handoff. Every selected feature must be `verified` or explicitly `deferred` with the user's acceptance and a next step.
