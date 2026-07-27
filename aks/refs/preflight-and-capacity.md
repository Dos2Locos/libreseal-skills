# Azure and AKS preflight

Use this reference for subscription discovery, regional/SKU checks, cluster selection, and safe cluster creation.

## Contents

- [Current official references](#current-official-references)
- [Tool and identity gate](#tool-and-identity-gate)
- [Capacity model](#capacity-model)
- [Inspect an existing cluster accurately](#inspect-an-existing-cluster-accurately)
- [Recommended predictable creation path](#recommended-predictable-creation-path)
- [AKS Automatic guardrail](#aks-automatic-guardrail)
- [Acceptance before application work](#acceptance-before-application-work)

## Current official references

- AKS VM sizes and availability: https://learn.microsoft.com/azure/aks/aks-virtual-machine-sizes
- Azure VM CLI: https://learn.microsoft.com/cli/azure/vm
- AKS Automatic: https://learn.microsoft.com/azure/aks/intro-aks-automatic
- AKS node auto-provisioning: https://learn.microsoft.com/azure/aks/node-auto-provisioning
- AKS cluster autoscaler: https://learn.microsoft.com/azure/aks/cluster-autoscaler-overview
- Azure CNI Overlay: https://learn.microsoft.com/azure/aks/azure-cni-overlay
- AKS pricing tiers: https://learn.microsoft.com/azure/aks/free-standard-pricing-tiers
- AKS application-routing Gateway API: https://learn.microsoft.com/azure/aks/app-routing-gateway-api

Check current docs and `az <command> --help` before creating infrastructure.

## Tool and identity gate

```bash
command -v az kubectl helm jq curl openssl
az version
az account show --query '{name:name,id:id,tenantId:tenantId,user:user.name}' -o yaml
```

If `az account show` fails, the user must authenticate in their terminal. Do not request Azure credentials in chat. If multiple subscriptions are relevant, list them and ask which one to activate:

```bash
az account list --query '[].{name:name,id:id,isDefault:isDefault,state:state}' -o table
az account set --subscription <chosen-name-or-id>
```

## Capacity model

Node allocation needs all of the following:

1. The VM SKU must be offered without a subscription restriction in the region.
2. Total regional vCPU quota must cover the planned nodes.
3. The SKU family quota must cover the same nodes.
4. Azure must have live physical capacity when allocation occurs.

The first three are inspectable; the fourth is not exposed as a reliable pre-allocation capacity inventory. A green preflight is eligibility, not a capacity reservation.

Budget for the maximum nodes that can coexist during installation, autoscaling, rolling upgrades, and surge. Example: two four-vCPU nodes plus one surge node require 12 regional and family vCPUs, not eight.

Perform the preflight directly from these Markdown commands.

First inspect the exact candidate SKU:

```bash
az vm list-skus \
  --location <region> \
  --resource-type virtualMachines \
  --size <vm-size> \
  --all \
  --query "[?name=='<vm-size>'].{name:name,family:family,zones:locationInfo[0].zones,restrictions:restrictions,compute:capabilities[?name=='vCPUs' || name=='MemoryGB']}" \
  -o json
```

Stop if there is no exact result. Treat any applicable `Location` or `Zone` restriction as a blocker for that placement. Record the `family` and integer `vCPUs`.

Then inspect total regional and family quota:

```bash
az vm list-usage \
  --location <region> \
  --query "[?name.value=='cores' || contains(name.value, 'Family')].{name:name.value,label:name.localizedValue,used:currentValue,limit:limit}" \
  -o json
```

Calculate and show:

```text
incremental_nodes = planned maximum nodes not already included in Azure's current usage
                   + maximum simultaneous upgrade-surge nodes
required_vcpus    = incremental_nodes * SKU vCPUs
regional_free     = regional cores limit - regional cores used
family_free       = matching VM-family limit - matching VM-family used
```

For multiple pools, group the peak requirement by VM family and also sum it for regional quota. Existing allocated nodes are already reflected in `currentValue`; do not double-count them. Autoscaler maximums not yet allocated do require headroom if the user expects scale-out to succeed. Stop when either free quota is below the calculated requirement and report both exact shortfalls.

Do not scan every Azure region by default. If the selected candidate fails, get the subscription's recommended physical regions and shortlist alternatives for latency, data residency, service availability, and cost:

```bash
az account list-locations \
  --query "[?metadata.regionType=='Physical' && metadata.regionCategory=='Recommended'].{name:name,displayName:displayName}" \
  -o table
```

When a quota is insufficient, show the exact regional and family shortfall and direct the user to Azure Quotas or a support quota request. Re-run `az vm list-usage` after approval; an approved total regional increase does not imply the family quota also changed.

Even when SKU eligibility and both quotas pass, live physical allocation can still fail. Do not describe this preflight as a reservation or capacity guarantee.

## Inspect an existing cluster accurately

```bash
az aks show --resource-group <resource-group> --name <cluster> -o json |
jq '{
  name,
  location,
  kind,
  sku,
  kubernetesVersion,
  nodeResourceGroup,
  nodeProvisioningProfile,
  agentPoolProfiles,
  networkProfile,
  ingressProfile,
  identity,
  oidcIssuerProfile,
  securityProfile,
  apiServerAccessProfile
}'
```

Also inspect live state:

```bash
kubectl get nodes -o wide
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get storageclass
kubectl get ingressclass
kubectl get ingress -A
kubectl get gatewayclass,gateway,httproute -A 2>/dev/null || true
kubectl get svc -A --field-selector spec.type=LoadBalancer
kubectl get nodepool,nodeclaim 2>/dev/null || true
```

Do not conflate:

- `sku.tier` (`Free`, `Standard`, or `Premium`) controls the AKS management tier/SLA.
- AKS Automatic is a managed cluster mode.
- `nodeProvisioningProfile.mode: Auto` is node auto-provisioning (NAP), which can also be enabled on AKS Standard.
- Cluster autoscaler scales known node pools and cannot be enabled together with NAP.

## Recommended predictable creation path

Use this Standard-provisioned template for the skill's default reproducible path. Replace values and add only the reviewed ingress flags after selecting the routing implementation.

```bash
az group create --name <resource-group> --location <region>

az aks create \
  --resource-group <resource-group> \
  --name <cluster> \
  --location <region> \
  --tier <Free-for-dev-or-Standard-for-production> \
  --node-count <initial-count> \
  --node-vm-size <quota-checked-vm-size> \
  --enable-cluster-autoscaler \
  --min-count <minimum-count> \
  --max-count <maximum-count> \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-dataplane cilium \
  --load-balancer-sku standard \
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --generate-ssh-keys
```

Validate every flag against the installed Azure CLI. Do not pin a Kubernetes version unless the user requires one; let Azure select a supported default, then record it.

Choose the ingress flags separately:

- For the current AKS application-routing Gateway API path, follow the current Microsoft guide. `--enable-app-routing-istio` enables the managed Gateway implementation; also use `--enable-app-routing` when its DNS/TLS operator integration is selected.
- For a time-bounded managed NGINX compatibility path, add `--enable-app-routing --app-routing-default-nginx-controller <External-or-Internal>`. Re-check the current support deadline and require an explicit migration plan for production.
- For a customer-managed controller, omit managed application-routing flags and validate that controller's AKS support and private/public Service design.

For production, use Standard tier, at least two schedulable workload nodes across zones where supported, maintenance windows, a tested upgrade policy, and enough max/surge quota. Decide private API access and Entra/Azure RBAC during architecture rather than retrofitting casually.

## AKS Automatic guardrail

AKS Automatic is a supported choice, but its managed routing defaults depend on Kubernetes/platform version. Newer clusters may use Gateway API, while older clusters can have the managed external NGINX controller. Inspect live state instead of assuming either.

The tested Phase workflow hit a specific reconciliation failure after changing an existing default NGINX application-routing controller from external to internal: Azure deleted the external load balancer while NAP still tried to attach new node NICs to its backend pool.

On Automatic:

- Preserve any preconfigured managed controller/Gateway and its load balancer.
- Create a separate reviewed private controller/Gateway for private ingress.
- Do not run `az aks approuting update --nginx Internal` as a generic conversion step.
- Do not add broad tolerations to Phase or Tailscale merely to run on hosted/system nodes.
- If NAP reports a deleted load-balancer reference, capture evidence and use the recovery playbook instead of modifying the `MC_*` resource group.

## Acceptance before application work

Continue only when:

- the active context is the intended cluster;
- existing nodes are `Ready`, or a clean Automatic cluster can provision a test workload node;
- selected storage can provision a test `ReadWriteOnce` PVC when bundled PostgreSQL is planned;
- region/SKU eligibility and both quotas cover current nodes plus planned headroom;
- no unknown public ingress or LoadBalancer conflicts with the chosen exposure model.
