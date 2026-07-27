# PostgreSQL and Redis choices on Azure

Use this reference when selecting, provisioning, or validating Phase backing services.

## Contents

- [Current official references](#current-official-references)
- [Choose PostgreSQL and Redis independently](#choose-postgresql-and-redis-independently)
- [Network discovery](#network-discovery)
- [Existing external services](#existing-external-services)
- [New Azure Database for PostgreSQL Flexible Server](#new-azure-database-for-postgresql-flexible-server)
- [New Azure Managed Redis](#new-azure-managed-redis)
- [Connectivity validation](#connectivity-validation)
- [Production acceptance](#production-acceptance)

## Current official references

- PostgreSQL Flexible Server CLI: https://learn.microsoft.com/cli/azure/postgres/flexible-server
- PostgreSQL networking: https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-networking
- PostgreSQL private endpoints: https://learn.microsoft.com/azure/postgresql/network/how-to-networking-servers-deployed-public-access-add-private-endpoint
- Azure Managed Redis: https://learn.microsoft.com/azure/redis/
- Azure Managed Redis CLI: https://learn.microsoft.com/cli/azure/redisenterprise
- Managed Redis create/manage example: https://learn.microsoft.com/azure/redis/scripts/create-manage-cache?pivots=azure-managed-redis

Re-open these before provisioning. Managed-service SKUs, regions, authentication defaults, and CLI extensions change independently of the Phase chart.

## Choose PostgreSQL and Redis independently

For each service choose one:

1. **Bundled** — fastest dev/test path; no Azure service to provision.
2. **Existing external** — obtain only non-secret endpoint/config details in chat; the user inserts credentials locally.
3. **New Azure managed** — preferred production direction, subject to cost, networking, region, HA, backup, and restore decisions.

Do not describe bundled services as production HA:

- PostgreSQL is one StatefulSet replica on one RWO volume.
- Redis is one ephemeral Deployment replica.
- The chart provides no automated data backups, replication, or failover.

Azure-managed does not automatically mean the complete Phase deployment is HA. Confirm the selected SKU/topology, zones, application replicas, proxy path, and restore procedure.

## Network discovery

Before creating private endpoints or delegated subnets, inspect AKS networking:

```bash
az aks show --resource-group <aks-resource-group> --name <cluster> \
  --query '{nodeResourceGroup:nodeResourceGroup,networkProfile:networkProfile,subnets:agentPoolProfiles[].vnetSubnetId}' \
  -o json
```

If subnet IDs are absent because Azure manages the VNet, inventory the cluster's node resource group read-only. Do not modify resources in `MC_*` without a supported design and explicit review.

Production preference:

- Place data endpoints on private connectivity reachable from AKS.
- Configure and test the correct private DNS zone/link.
- Do not use an `Allow Azure services`/`0.0.0.0` firewall shortcut as a production trust boundary.
- Keep PostgreSQL and Redis in the same or latency-appropriate region as AKS.
- Use TLS and test certificate validation from the actual workload network.

## Existing external services

Collect non-secret values:

### PostgreSQL

- FQDN and port
- database and username
- required SSL mode
- public firewall or private VNet/endpoint path
- CA requirements
- backup/restore owner and RPO/RTO

### Redis

- FQDN and TLS port
- ACL username if required
- TLS/CA requirements
- eviction and persistence policy
- HA/failover behavior

Have the user put passwords into `phase-console-secret` with the command in `phase-chart.md`. Never ask them to paste passwords or access keys.

## New Azure Database for PostgreSQL Flexible Server

Agree on server name, version, tier/SKU, storage/autogrow, HA mode, backup retention/geo-redundancy, maintenance window, and network model before creation. Show the estimated billable resources.

For VNet-integrated private access, use a dedicated empty subnet delegated to PostgreSQL and an appropriate private DNS zone. Do not reuse the AKS node subnet. Validate the current CLI syntax; a representative user-side pattern is:

```bash
read -rsp "New PostgreSQL administrator password: " PHASE_DATABASE_PASSWORD; echo

az postgres flexible-server create \
  --resource-group <data-resource-group> \
  --name <postgres-server> \
  --location <region> \
  --admin-user <phase-admin-user> \
  --admin-password "$PHASE_DATABASE_PASSWORD" \
  --version <supported-version> \
  --tier <GeneralPurpose-or-approved-tier> \
  --sku-name <selected-sku> \
  --storage-size <gib> \
  --subnet <dedicated-postgres-subnet-id> \
  --private-dns-zone <private-dns-zone-id> \
  --high-availability <ZoneRedundant-or-SameZone-or-Disabled>

az postgres flexible-server db create \
  --resource-group <data-resource-group> \
  --server-name <postgres-server> \
  --database-name phase

# Use this same shell variable while creating phase-console-secret, then:
unset PHASE_DATABASE_PASSWORD
```

The user runs this because the password must not enter the agent context. Do not let Azure CLI auto-generate and print a password into agent logs.

Configure Phase with the server's FQDN, database, and user, plus both `database.sslmode: require` and `database.ssl: true` for chart `1.0.2`.

For Private Link instead of VNet integration, create the server with public access disabled, create a private endpoint in a reachable VNet subnet, and link `privatelink.postgres.database.azure.com` according to the current Microsoft guide. Do not mix DNS-zone conventions from the two network models.

## New Azure Managed Redis

Azure Managed Redis uses the `redisenterprise` Azure CLI extension. Confirm region/SKU availability and cost before installing the extension or creating a cache:

```bash
az extension show --name redisenterprise 2>/dev/null || az extension add --name redisenterprise
az redisenterprise create --help
```

Representative creation pattern:

```bash
az redisenterprise create \
  --name <redis-name> \
  --resource-group <data-resource-group> \
  --location <region> \
  --sku <selected-managed-redis-sku>
```

New Azure Managed Redis favors Microsoft Entra authentication and TLS. The current Phase chart accepts a static Redis username/password and does not express token-based Managed Redis authentication. For a chart-compatible deployment, explicitly verify that access-key authentication is enabled on the database, use only the TLS port, and record this credential-management tradeoff. Do not enable plaintext access.

Retrieve the endpoint without retrieving keys:

```bash
az redisenterprise show \
  --name <redis-name> \
  --resource-group <data-resource-group> \
  --query '{host:hostName,tlsPort:sslPort,nonTlsEnabled:enableNonSslPort,sku:sku.name}' \
  -o yaml
```

Have the user capture the primary key directly into their local shell and place it into the Phase Secret without printing it:

```bash
PHASE_REDIS_PASSWORD="$(az redisenterprise database list-keys \
  --cluster-name <redis-name> \
  --resource-group <data-resource-group> \
  --query primaryKey -o tsv)"

# Use PHASE_REDIS_PASSWORD while creating phase-console-secret, then:
unset PHASE_REDIS_PASSWORD
```

If updating an existing Phase Secret, provide a user-run local patch that base64-encodes the variable without displaying it. Never execute `list-keys` in the agent's logged context.

Configure Phase with the reported hostname/TLS port, `redis.ssl: true`, and the provider-required ACL user. Confirm current Azure documentation; do not assume `default` blindly.

Create private connectivity and DNS before Phase installation. The cache's default public-network posture can change by SKU/version, so inspect the live resource rather than assuming it is private.

## Connectivity validation

Before Phase installation, validate non-secret network properties from a disposable pod:

```bash
kubectl -n phase run network-check --rm -i --restart=Never \
  --image=<approved-diagnostic-image@sha256:digest> -- \
  sh -c 'getent hosts <fqdn> && curl --verbose --connect-timeout 5 telnet://<fqdn>:<port>'
```

Use a pinned digest from the customer's approved registry. The test must resolve to the intended private address and connect to the TLS port. A TCP connection does not prove authentication or application compatibility.

After Phase is installed, migrations and readiness prove credentialed connectivity. Check logs for TLS/auth failures without printing secrets:

```bash
kubectl -n phase logs deployment/phase-console-backend --tail=100
kubectl -n phase logs deployment/phase-console-worker --tail=100
```

## Production acceptance

Do not mark managed data complete until:

- private DNS and routing work from Phase pods;
- public access is disabled or narrowly justified;
- TLS is enabled and certificate verification behavior is understood;
- passwords/keys are stored and recoverable through approved systems;
- HA/failover settings are recorded and tested where required;
- PostgreSQL backups and an actual restore test meet RPO/RTO;
- Redis persistence/eviction and data-loss expectations are explicit;
- key/password rotation has a tested Phase Secret update and rollout procedure.
