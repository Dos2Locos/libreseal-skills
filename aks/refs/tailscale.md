# Tailscale ingress, Funnel, and tailnet egress

Use this reference only when the user selects Tailscale. Treat tailnet policy, Kubernetes resources, application authentication, and HA as separate controls.

## Contents

- [Current official references](#current-official-references)
- [Architecture](#architecture)
- [Choose standalone or ProxyGroup](#choose-standalone-or-proxygroup)
- [Tailnet policy](#tailnet-policy)
- [Operator authentication](#operator-authentication)
- [Install and pin the operator](#install-and-pin-the-operator)
- [Private ingress bridge](#private-ingress-bridge)
- [Phase values for Tailscale ingress](#phase-values-for-tailscale-ingress)
- [Funnel](#funnel)
- [Destination-specific egress](#destination-specific-egress)
- [Tailscale acceptance](#tailscale-acceptance)

## Current official references

- Install the operator: https://tailscale.com/docs/kubernetes-operator/install-operator
- Operator overview: https://tailscale.com/docs/kubernetes-operator
- Ingress and HA: https://tailscale.com/docs/kubernetes-operator/ingress
- Funnel from Kubernetes: https://tailscale.com/docs/kubernetes-operator/ingress/expose-workload-to-internet
- Egress and HA: https://tailscale.com/docs/kubernetes-operator/egress
- ProxyGroup: https://tailscale.com/docs/kubernetes-operator/concepts/proxygroup
- ProxyGroup namespace policy: https://tailscale.com/docs/kubernetes-operator/manage-and-configure/proxy-group-policy
- Operator permissions/RBAC: https://tailscale.com/docs/kubernetes-operator/reference/rbac
- Workload identity federation: https://tailscale.com/docs/kubernetes-operator/manage-and-configure/workload-identity-federation
- Operator limitations: https://tailscale.com/docs/kubernetes-operator/reference/limitations

Re-open these and inspect the selected operator chart/CRDs. Tailscale capabilities have evolved materially between releases.

## Architecture

Private ingress:

```text
tailnet client -> Tailscale ingress proxy -> AKS NGINX/controller -> Phase frontend/backend
```

Funnel adds a public Tailscale relay in front of an Ingress hostname. It does not add Phase authentication. If Funnel is enabled on the main bridge, the whole Phase hostname is public, not only SCIM or one API path.

Destination-specific egress:

```text
each Phase backend/worker replica
  -> phase-tailnet-target.phase.svc.cluster.local:8443
  -> Tailscale egress proxy or egress ProxyGroup
  -> target-node.tail123abc.ts.net:8443
```

Normal AKS pods do not automatically get MagicDNS or unrestricted tailnet routes merely because the operator is installed. Create one annotated Kubernetes Service per intended tailnet destination, or deliberately configure the operator's DNS feature after reviewing its blast radius.

The tailnet leg is encrypted by Tailscale/WireGuard. Pod-to-proxy and target-daemon-to-local-service traffic may still be plaintext; use HTTPS or mTLS for end-to-end application encryption.

## Choose standalone or ProxyGroup

- Standalone creates one proxy StatefulSet per Ingress/Service. It is simple and suitable for development, but the proxy is a single availability dependency.
- ProxyGroup creates shared multi-replica ingress or egress proxies and is the production preference. Application replicas alone do not make a standalone proxy HA.
- Target services need their own HA. A two-replica egress ProxyGroup cannot make one workstation or one LiteLLM process highly available.

For Funnel, do not assume a ProxyGroup annotation makes the public path HA. The 2026 official docs describe ProxyGroup HA ingress and Funnel separately, while the Funnel example does not explicitly demonstrate their combination. Verify the selected release's documentation and test proxy failover through the public path before claiming HA.

## Tailnet policy

Merge objects into the existing policy; never replace the whole policy. If the session cannot edit tailnet policy, print a valid JSON/HuJSON merge fragment, identify the exact existing arrays/maps it affects, and wait for a tailnet administrator to apply and validate it.

### Standalone proxy tags

```json
{
  "groups": {
    "group:phase-admins": [
      "alice@example.com",
      "bob@example.com"
    ]
  },
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:phase-aks-ingress": ["tag:k8s-operator"],
    "tag:phase-aks-egress": ["tag:k8s-operator"]
  },
  "grants": [
    {
      "src": ["group:phase-admins"],
      "dst": ["tag:phase-aks-ingress"],
      "ip": ["tcp:443"]
    }
  ]
}
```

Replace identities with real full Tailscale login names. Group names begin with `group:` and cannot contain other groups. Tag ownership lets the operator assign tags; it does not grant users network access.

### ProxyGroup policy difference

HA ingress uses Tailscale Services. ProxyGroup device tags, advertised Service tags, auto-approval, and user access are distinct. Read the current RBAC/policy guide and configure:

- a ProxyGroup device tag owned by `tag:k8s-operator`;
- `tailscale.com/tags` on the Ingress/Service for the advertised Tailscale Service;
- `autoApprovers.services` so the ProxyGroup devices may advertise that Service tag;
- grants from the intended users/groups to the Service tag.

Do not reuse a standalone-device grant blindly for ProxyGroup mode.
On a shared cluster, consider `ProxyGroupPolicy` so only approved namespaces can reference the selected ingress/egress ProxyGroups.

## Operator authentication

### OAuth client

In **Trust credentials**, create a client tagged `tag:k8s-operator` with read/write access for:

- General / Services
- Devices / Core
- Keys / Auth Keys

The operator exchanges this client credential for short-lived API tokens, but the OAuth client secret itself remains a stored credential. Have the user create the Kubernetes Secret locally:

```bash
kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -

read -rp "Tailscale OAuth client ID: " TS_CLIENT_ID
read -rsp "Tailscale OAuth client secret: " TS_CLIENT_SECRET; echo

kubectl -n tailscale create secret generic operator-oauth \
  --from-literal=client_id="$TS_CLIENT_ID" \
  --from-literal=client_secret="$TS_CLIENT_SECRET"

unset TS_CLIENT_ID TS_CLIENT_SECRET
```

If `operator-oauth` exists, leave it unchanged unless performing a deliberate rotation. Verify keys only:

```bash
kubectl -n tailscale get secret operator-oauth -o json | jq -r '.data | keys[]'
```

Inspect the selected operator chart to confirm it consumes the pre-created `operator-oauth` Secret, or set the chart's current existing-Secret option. Never fall back to passing the OAuth secret with `--set-string`, because that stores it in shell history and Helm release metadata.

### Workload identity federation

Tailscale's workload identity federation can remove the stored OAuth client secret, but is beta and requires the cluster's OIDC discovery endpoint to be publicly reachable plus a specific unauthenticated discovery binding. Present this security tradeoff and follow the current official guide exactly; do not silently add a cluster-wide binding.

## Install and pin the operator

```bash
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update tailscale
helm search repo tailscale/tailscale-operator --versions
helm show values tailscale/tailscale-operator --version <operator-version> > tailscale-values.reference.yaml
```

Use a minimal resource override if needed:

```yaml
operatorConfig:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 500m
      memory: 256Mi
```

```bash
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --version <operator-version> \
  --namespace tailscale \
  --create-namespace \
  --values tailscale-operator-values.yaml \
  --wait \
  --timeout 10m

kubectl -n tailscale get deployment,pods
kubectl get ingressclass tailscale
kubectl get crd proxyclasses.tailscale.com proxygroups.tailscale.com
```

The operator should appear in the admin console tagged `tag:k8s-operator`. If its pod is Pending, diagnose scheduling/NAP before changing Tailscale configuration.

## Private ingress bridge

The bridge points Tailscale at the internal controller Service; it is created before Phase solely to obtain the final hostname. Discover the Service name/port first:

```bash
kubectl -n app-routing-system get services -o wide
```

The example below uses the AKS managed NGINX compatibility path. Before production use, verify that controller is still supported or adapt the bridge to the customer's maintained internal routing tier.

Optional resource-bounded `ProxyClass` for standalone proxies:

```yaml
apiVersion: tailscale.com/v1alpha1
kind: ProxyClass
metadata:
  name: phase-aks-proxy
spec:
  statefulSet:
    pod:
      tailscaleContainer:
        resources:
          requests: {cpu: 100m, memory: 128Mi}
          limits: {cpu: 500m, memory: 512Mi}
      tailscaleInitContainer:
        resources:
          requests: {cpu: 10m, memory: 32Mi}
          limits: {cpu: 100m, memory: 128Mi}
```

Standalone bridge:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: phase-tailscale-bridge
  namespace: app-routing-system
  annotations:
    tailscale.com/proxy-class: "phase-aks-proxy"
    tailscale.com/tags: "tag:phase-aks-ingress"
spec:
  ingressClassName: tailscale
  defaultBackend:
    service:
      name: <actual-internal-controller-service>
      port:
        number: 80
  tls:
    - hosts:
        - phase-aks
```

For HA private ingress, create a current-version `ProxyGroup` with `spec.type: ingress` and at least two replicas, apply its policy/auto-approver requirements, and add `tailscale.com/proxy-group: <name>` to the bridge. Do not combine standalone-only assumptions with ProxyGroup mode.

```bash
kubectl apply --dry-run=server -f tailscale-proxy-class.yaml -f tailscale-bridge.yaml
kubectl apply -f tailscale-proxy-class.yaml -f tailscale-bridge.yaml
kubectl -n app-routing-system wait ingress/phase-tailscale-bridge \
  --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
  --timeout=10m

PHASE_HOST="$(kubectl -n app-routing-system get ingress phase-tailscale-bridge \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
printf 'Phase hostname: %s\n' "$PHASE_HOST"
test -n "$PHASE_HOST"
```

An NGINX `404` before Phase installation is expected and proves Tailscale reached the controller. Use the exact reported `.ts.net` hostname in `global.host` and `ingress.host` before Helm install.

Tailscale certificates expose machine names in public Certificate Transparency logs. Use non-sensitive hostnames.

## Phase values for Tailscale ingress

Tailscale terminates public-trust TLS and sends in-cluster HTTP to the controller:

```yaml
ingress:
  enabled: true
  className: "<internal-controller-class>"
  host: "<exact-tailscale-hostname>"
  tls: []

certManager:
  enabled: false
```

### Real client IP through Tailscale and NGINX

Discover the live pod CIDR:

```bash
az aks show --resource-group <resource-group> --name <cluster> \
  --query networkProfile.podCidr -o tsv
```

For the tested Tailscale-to-NGINX path, add to the Phase Ingress values:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/configuration-snippet: |
      set_real_ip_from <exact-aks-pod-cidr>;
      real_ip_header X-Forwarded-For;
      real_ip_recursive on;
```

Tailscale replaces inbound `X-Forwarded-For` with the source it observes. NGINX must trust only the actual proxy source boundary or it records the proxy pod IP.

Never use `0.0.0.0/0`. Trusting the entire pod CIDR permits any pod that can reach NGINX to forge the header. Enforce NetworkPolicy or use a narrower dedicated proxy boundary before treating the result as a production security control.

Validate new events:

- private tailnet request: a Tailscale IPv4 (`100.64.0.0/10`) or Tailscale IPv6;
- Funnel request: the public caller/NAT egress address;
- never the Tailscale proxy's AKS pod address.

## Funnel

Funnel on the main bridge publishes the complete Phase hostname to the internet. Prefer the existing bridge only when full-host public exposure is approved; private and public callers then use the same `.ts.net` hostname and Phase host/origin/cookie configuration does not change.

If only SCIM, webhook, or selected public API paths may be exposed, do not annotate the main bridge. First verify the selected Phase version supports a separate public hostname in allowed hosts/origins and that every required endpoint works without exposing UI or unrelated API routes. Then create a dedicated Funnel Ingress with only the reviewed routes. If that contract cannot be proven, state that Funnel would expose the whole hostname and ask the user to choose a WAF/API gateway or accept full-host exposure.

Only after authentication is tested, merge a node attribute for the proxy tag:

```json
{
  "nodeAttrs": [
    {
      "target": ["tag:phase-aks-ingress"],
      "attr": ["funnel"]
    }
  ]
}
```

`autogroup:member` does not include tagged proxy devices. Then enable Funnel deliberately:

```bash
kubectl -n app-routing-system annotate ingress phase-tailscale-bridge \
  tailscale.com/funnel=true --overwrite
```

Verify public DNS without letting local MagicDNS mask the result. Resolve through DNS-over-HTTPS, then force the public relay IP while retaining TLS SNI/Host and bypassing proxies:

```bash
curl --silent --show-error \
  --header 'accept: application/dns-json' \
  "https://cloudflare-dns.com/dns-query?name=<tailscale-hostname>&type=A" | jq .

curl --fail --show-error --noproxy '*' \
  --resolve '<tailscale-hostname>:443:<public-funnel-ip>' \
  'https://<tailscale-hostname>/api/health'
```

Test UI, `/service/health/`, required external API/SCIM endpoints, unauthenticated denial, client IP, and private tailnet access to the same hostname. Transport encryption does not protect a weak registration/authentication posture.

Rollback public exposure without changing the hostname:

```bash
kubectl -n app-routing-system annotate ingress phase-tailscale-bridge tailscale.com/funnel-
```

Confirm public DNS/access disappear while private tailnet access remains.

## Destination-specific egress

Standalone example:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: phase-tailnet-target
  namespace: phase
  annotations:
    tailscale.com/tailnet-fqdn: "target-node.tail123abc.ts.net"
    tailscale.com/tags: "tag:phase-aks-egress"
    tailscale.com/proxy-class: "phase-aks-proxy"
spec:
  type: ExternalName
  externalName: placeholder
  ports:
    - name: target
      protocol: TCP
      port: 8443
      targetPort: 8443
```

For production HA, create an egress ProxyGroup with at least two replicas and add:

```yaml
metadata:
  annotations:
    tailscale.com/proxy-group: "phase-egress"
```

HA ExternalName Services require explicit ports. One egress ProxyGroup can serve multiple destination Services, but each Service remains scoped to one tailnet FQDN/IP and declared ports.

```bash
kubectl apply --dry-run=server -f phase-tailnet-egress.yaml
kubectl apply -f phase-tailnet-egress.yaml
kubectl -n phase get service phase-tailnet-target -o yaml
kubectl -n tailscale get proxygroup,statefulset,pods 2>/dev/null || true
```

Wait for the condition emitted by the selected version. Operator `1.98.9` used `TailscaleProxyReady=True`; do not hard-code an obsolete condition name.

Every backend and worker replica connects to the stable Kubernetes name:

```text
phase-tailnet-target.phase.svc.cluster.local:8443
```

Test from both a backend pod and a worker pod, using a non-secret health/readiness endpoint. Validate credentials through the application without displaying them.

## Tailscale acceptance

Do not mark complete until:

- operator and selected proxy/ProxyGroup replicas are Ready;
- private hostname and certificate validate;
- Phase uses that exact host everywhere;
- tailnet policy allows intended identities and denies unintended ones;
- Funnel, if selected, is tested from outside the tailnet and can be rolled back;
- client IP attribution matches the path;
- every selected egress destination works from backend and worker replicas;
- standalone versus HA and target-side availability are documented accurately.
