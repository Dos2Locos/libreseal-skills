# AKS deployment troubleshooting

Read this before changing infrastructure. Capture non-secret evidence first; diagnose the owning layer instead of masking symptoms.

## Contents

- [First-response bundle](#first-response-bundle)
- [Node allocation: quota versus live capacity](#node-allocation-quota-versus-live-capacity)
- [Pending pod](#pending-pod)
- [AKS Automatic NAP references a deleted load balancer](#aks-automatic-nap-references-a-deleted-load-balancer)
- [LoadBalancer address is pending or unexpectedly public](#loadbalancer-address-is-pending-or-unexpectedly-public)
- [PVC Pending or RWO multi-attach](#pvc-pending-or-rwo-multi-attach)
- [Helm install hangs while pods wait for migrations](#helm-install-hangs-while-pods-wait-for-migrations)
- [Stale hostname, CSP, wrong API base, or allowed-host errors](#stale-hostname-csp-wrong-api-base-or-allowed-host-errors)
- [Tailscale operator Pending or not joining](#tailscale-operator-pending-or-not-joining)
- [Audit logs show an AKS proxy pod IP](#audit-logs-show-an-aks-10x-proxy-pod-ip)
- [Pods cannot resolve a tailnet hostname](#pods-cannot-resolve-a-tailnet-hostname)
- [Funnel appears private or public tests hit MagicDNS](#funnel-appears-private-or-public-tests-hit-magicdns)
- [Rollback principles](#rollback-principles)

## First-response bundle

```bash
date -u
az account show --query '{name:name,id:id,tenantId:tenantId}' -o yaml
kubectl config current-context
kubectl version
helm version
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -n 100
kubectl get ingressclass
kubectl get ingress -A -o wide
kubectl get svc -A --field-selector spec.type=LoadBalancer -o wide
kubectl get storageclass,pv,pvc -A
helm list -A
```

Add cluster posture without secrets:

```bash
az aks show --resource-group <resource-group> --name <cluster> -o json |
jq '{name,location,kind,sku,nodeResourceGroup,nodeProvisioningProfile,agentPoolProfiles,networkProfile,ingressProfile,provisioningState}'
```

Record exact timestamps, resource IDs, Azure correlation/deployment operation IDs, pod events, and the first failing layer. Redact user identities and never collect Secret data or credential-bearing environment variables.

## Node allocation: quota versus live capacity

Typical errors mention regional quota, VM-family quota, SKU restrictions, `AllocationFailed`, or insufficient capacity.

1. Repeat the individual SKU and quota commands in `preflight-and-capacity.md` with all simultaneous existing/planned/surge nodes included.
2. Inspect `az vm list-skus --all` restrictions.
3. Inspect total regional and exact family usage and recalculate both shortfalls.
4. Check Azure Service Health and the deployment operation.

If quota is low, request both required quotas. If quota and SKU eligibility pass but allocation still fails, treat it as live capacity: try another zone/SKU family or a compliant alternate region. Never claim the preflight proves physical inventory.

## Pending pod

```bash
kubectl -n <namespace> describe pod <pod>
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints,UNSCHEDULABLE:.spec.unschedulable'
kubectl top nodes 2>/dev/null || true
kubectl get nodepool,nodeclaim -o wide 2>/dev/null || true
kubectl describe nodeclaim <name> 2>/dev/null || true
```

Classify the event:

- insufficient CPU/memory: fix resource/node capacity and quota;
- unbound PVC: fix storage class/topology;
- taints: determine why the workload has no normal node; do not add broad hosted/system tolerations;
- affinity/topology: correct workload constraints;
- NAP node claim failure: inspect the cloud error before touching the pod.

The Tailscale operator Pending on an AKS Automatic cluster is often an AKS workload-node problem, not OAuth or Tailscale.

## AKS Automatic NAP references a deleted load balancer

Known signature: a NodeClaim or VMSS/NIC operation fails with `InvalidResourceReference` for a backend pool below a deleted `/loadBalancers/kubernetes`, often after the application-routing default controller was switched from external to internal.

Capture:

```bash
kubectl get nodeclaim -o yaml 2>/dev/null
kubectl get events -A --sort-by=.lastTimestamp | tail -n 150
az aks show --resource-group <resource-group> --name <cluster> --query ingressProfile -o yaml
az network lb list --resource-group "$(az aks show -g <resource-group> -n <cluster> --query nodeResourceGroup -o tsv)" -o table
```

Query Azure Activity Log around the failure for load balancer create/delete and NIC/VMSS operations. Use the exact node resource group and time range; retain correlation IDs.

Do not:

- recreate or hand-edit the AKS-managed load balancer/backend pool in `MC_*`;
- repeatedly issue empty `az aks update` calls as a presumed repair;
- tolerate hosted/system taints to force application pods onto service-managed nodes.

Supported direction:

- if the cluster is otherwise recoverable, work with Azure support using captured correlation IDs;
- preserve the default external controller and create a separate internal `NginxIngressController` on a healthy cluster;
- for a fresh disposable cluster, recreate using the reviewed Standard path rather than carrying unknown managed-state drift.

Cluster recreation is not the first response for ordinary Pending pods, but it can be the safest response for a fresh empty cluster with broken managed infrastructure. Inventory data/PVCs/public IPs/DNS/tailnet devices before deletion.

## LoadBalancer address is pending or unexpectedly public

```bash
kubectl -n app-routing-system describe service <controller-service>
kubectl -n app-routing-system get service <controller-service> -o yaml
az network lb list --resource-group <node-resource-group> -o table
```

Check controller annotations, subnet permissions/capacity, Azure events, and selected `NginxIngressController`. For a tailnet-only design, stop if the controller has a public frontend. Do not rely on absence of DNS as an access control; an IP plus Host header may still reach an Ingress.

## PVC Pending or RWO multi-attach

```bash
kubectl -n phase get pvc,pods -o wide
kubectl -n phase describe pvc <pvc>
kubectl -n phase describe pod <postgres-pod>
kubectl get volumeattachment
```

Check the default/selected StorageClass, zone constraints, CSI events, old pod termination, and disk attachment state. Bundled PostgreSQL on one RWO disk can pause during node consolidation or drain while Azure detaches/reattaches it. Do not force-detach a disk until the old node/pod state and corruption risk are understood.

For production, move to a tested managed PostgreSQL topology instead of presenting a PDB as data HA.

## Helm install hangs while pods wait for migrations

Chart `1.0.2` uses a post-install/post-upgrade migration hook while application init containers wait for migrations. `--wait` or `--atomic` can prevent Helm from reaching the hook.

Inspect:

```bash
helm -n phase status phase-console --show-resources
kubectl -n phase get pods,jobs
kubectl -n phase describe pod <waiting-pod>
helm template phase-console phase/phase --version <version> -n phase -f phase-values.yaml | rg -n 'helm.sh/hook|wait-for-migrations'
```

If the rendered chart has this ordering, rerun `helm upgrade --install` without `--wait`/`--atomic`. Do not delete the database or Secret. A successful hook may delete its Job automatically.

## CrashLoopBackOff or init-container failure

```bash
kubectl -n phase describe pod <pod>
kubectl -n phase logs <pod> --all-containers --tail=150
kubectl -n phase logs <pod> --all-containers --previous --tail=150
kubectl -n phase get secret phase-console-secret -o json | jq -r '.data | keys[]'
```

Check expected key names, database/Redis DNS, port/TLS/user configuration, migrations, allowed host/origin, and image compatibility. Never decode the Secret. Have the user correct a value locally if needed.

## Stale hostname, CSP, wrong API base, or allowed-host errors

Symptoms include requests to `phase-dev.invalid`, CSP blocks, bad OAuth redirects, cookie failures, or backend `DisallowedHost`.

```bash
helm -n phase get values phase-console
kubectl -n phase get configmap phase-console-config -o yaml
kubectl -n phase exec deployment/phase-console-frontend -- printenv HOST NEXT_PUBLIC_BACKEND_API_BASE
kubectl -n phase exec deployment/phase-console-backend -- printenv HOST ALLOWED_HOSTS ALLOWED_ORIGINS
```

Do not print secret variables. Ensure the exact final hostname is in `global.host` and `ingress.host`. If the chart lacks ConfigMap checksums:

```bash
kubectl -n phase rollout restart \
  deployment/phase-console-frontend \
  deployment/phase-console-backend \
  deployment/phase-console-worker
```

Verify rollouts and live values. This is why ingress/hostname must precede the first install.

## External PostgreSQL or Redis timeout/TLS/authentication

Check in order:

1. Kubernetes DNS resolves the intended private address.
2. Route/NSG/firewall/private endpoint allows the pod/node source.
3. Port is the TLS port.
4. PostgreSQL has both chart `sslmode` and application `ssl` enabled where required.
5. Redis username and access-key mode match the service.
6. Credentials in the Secret match, verified by the user locally rather than decoded by the agent.

Use non-secret TCP/TLS probes first. Then inspect Phase init/application logs for auth outcome. Do not weaken TLS or enable broad public Azure access merely to make the test pass.

## Tailscale operator Pending or not joining

```bash
kubectl -n tailscale describe deployment operator
kubectl -n tailscale describe pod -l app=operator
kubectl -n tailscale logs deployment/operator --tail=150
kubectl -n tailscale get secret operator-oauth -o json | jq -r '.data | keys[]'
```

- Pending: solve node scheduling/NAP/taint first.
- Running but unauthorized: confirm key names, OAuth scopes, OAuth tag, and tailnet tag ownership. Have the user rotate locally if needed.
- CRDs/IngressClass absent: verify pinned chart status and compatibility.

Never request the OAuth secret in chat or pass it through Helm command-line values when a pre-created Secret is used.

## Tailscale ingress hostname exists but Phase returns 404/502

- `404` before Phase: expected proof that bridge reaches NGINX with no matching Phase route.
- `404` after Phase: compare final hostname in bridge, Phase Ingress, `global.host`, and HTTP Host.
- `502/504`: check backend/frontend Services, endpoints, readiness, and controller logs.

```bash
kubectl -n app-routing-system get ingress phase-tailscale-bridge -o wide
kubectl -n phase get ingress,svc,endpoints -o wide
kubectl -n app-routing-system logs deployment/<controller> --tail=150
```

## Audit logs show an AKS `10.x` proxy pod IP

Map the recorded IP to pods:

```bash
kubectl get pods -A -o wide | rg '<recorded-ip>'
```

If it is the Tailscale ingress proxy, NGINX is not trusting Tailscale's canonical `X-Forwarded-For`. Apply the narrow real-IP annotation in `tailscale.md` using the selected proxy source boundary, then generate a new event. Never rewrite historical rows or trust `0.0.0.0/0`.

Prefer the current proxy pod `/32` for a narrow immediate repair, and record that it must be refreshed after standalone proxy recreation. For a durable setup, use a dedicated proxy boundary plus NetworkPolicy. Treat full pod-CIDR trust as spoofable while any other pod can reach NGINX.

Inspect rendered NGINX configuration to confirm `set_real_ip_from`, `real_ip_header X-Forwarded-For`, and recursion are active. Generate fresh requests on every enabled path:

- tailnet ingress should record the caller's Tailscale IPv4/IPv6;
- Funnel should record the public caller/NAT IPv4 or IPv6;
- neither should record the proxy pod address.

## Pods cannot resolve a tailnet hostname

This is expected by default. Operator installation does not inject MagicDNS into all pods. Create an annotated destination-specific `ExternalName` Service first.

Choose the application name by transport:

- For raw TCP or explicitly accepted plaintext HTTP, connect to the Kubernetes Service name.
- For HTTPS with a certificate issued to the MagicDNS hostname, keep the MagicDNS URL in the application and route that DNS name to the egress Service. Use the official Tailscale `DNSConfig` plus CoreDNS stub, or an exact AKS `coredns-custom` rewrite for one hostname.

Do not replace an HTTPS URL with the Kubernetes Service hostname unless its certificate covers that name, and never disable TLS verification.

Check:

```bash
kubectl -n phase get service <egress-service> -o yaml
kubectl -n kube-system get configmap coredns-custom -o yaml 2>/dev/null || true
kubectl get dnsconfig 2>/dev/null || true
kubectl -n tailscale get statefulset,pods -o wide
kubectl -n tailscale get proxygroup 2>/dev/null || true
```

Wait for the current release's readiness condition (operator `1.98.9` emitted `TailscaleProxyReady=True`). Verify DNS and certificate validation from every backend and worker replica. One Service maps only its declared destination and ports.

## Funnel appears private or public tests hit MagicDNS

Tagged proxies need the `funnel` node attribute explicitly; `autogroup:member` does not include them. Confirm the annotation and proxy capability.

Local DNS may intercept the tailnet's `.ts.net` domain and hide public Funnel records. Use DNS-over-HTTPS, then `curl --resolve` with `--noproxy '*'` against a public relay IP. Preserve the hostname for TLS SNI and Host.

If public tests still fail, remove the Funnel annotation to return to the known private state, inspect operator/proxy logs, and verify current release support. Do not disable TLS verification. Keep Funnel marked `selected` or `deferred`; do not silently report the private route as the requested final exposure.

## Rollback principles

- Funnel: remove only `tailscale.com/funnel`; private Serve should remain.
- Phase config: retain the Secret/database, restore the previous values/version, and account for migration compatibility.
- Tailscale egress: delete only the specific Service after confirming no application uses its stable DNS name.
- Ingress controller: do not delete a shared controller without inventorying all Ingresses.
- Cluster/data: require explicit destructive approval and verified backups.

After any repair, rerun the full applicable acceptance set rather than checking only the original symptom.
