# AKS ingress and hostname design

Use this reference for public Azure ingress, an internal controller behind Tailscale, or a bring-your-own controller.

## Contents

- [Current official references](#current-official-references)
- [Ingress-first rule](#ingress-first-rule)
- [Controller lifecycle decision](#controller-lifecycle-decision)
- [Public Gateway API path](#public-gateway-api-path)
- [Managed NGINX compatibility path](#managed-nginx-compatibility-path)
- [Private NGINX path](#private-nginx-path)
- [Bring-your-own controller or NGINX-free path](#bring-your-own-controller-or-nginx-free-path)
- [DNS and TLS validation](#dns-and-tls-validation)
- [Exposure acceptance](#exposure-acceptance)

## Current official references

- AKS application routing: https://learn.microsoft.com/azure/aks/app-routing
- AKS application-routing Gateway API: https://learn.microsoft.com/azure/aks/app-routing-gateway-api
- Gateway API DNS and TLS integration: https://learn.microsoft.com/azure/aks/app-routing-gateway-api-dns-tls
- Multiple/internal NGINX controllers: https://learn.microsoft.com/azure/aks/app-routing-nginx-configuration
- Internal controller/private DNS: https://learn.microsoft.com/azure/aks/create-nginx-ingress-private-controller
- AKS application networking options: https://learn.microsoft.com/azure/aks/plan-application-networking
- Restrict LoadBalancer source ranges: https://learn.microsoft.com/azure/aks/configure-load-balancer-standard#restrict-inbound-traffic-to-specific-ip-ranges
- cert-manager installation: https://cert-manager.io/docs/installation/

Microsoft currently states that AKS managed NGINX receives critical security support only through November 2026 and recommends Gateway API as the successor. Re-open the current AKS guidance before choosing a controller. The Phase chart's current NGINX-specific Ingress is a compatibility constraint, not a reason to start a production deployment on a retiring path.

## Ingress-first rule

Resolve these before installing Phase:

1. Controller/class and whether it is public, private, or tailnet-only.
2. Final hostname.
3. TLS termination and certificate owner.
4. Bootstrap source restriction.
5. Forwarded-client-IP trust boundary.

The final hostname must be set in both `global.host` and the chart-managed `ingress.host`. A placeholder causes stale frontend API URLs, CSP/origin failures, cookie/redirect mismatches, and allowed-host errors.

Inventory shared-cluster impact first:

```bash
kubectl get ingressclass
kubectl get ingress -A -o wide
kubectl get gatewayclass
kubectl get gateway,httproute -A
kubectl get svc -A --field-selector spec.type=LoadBalancer -o wide
kubectl get nginxingresscontroller 2>/dev/null || true
az aks show --resource-group <resource-group> --name <cluster> --query ingressProfile -o yaml
```

Do not change a cluster-wide controller mode until every existing Ingress owner accepts the exposure change.

## Controller lifecycle decision

For a new production deployment, prefer the customer's supported Gateway API/controller standard. Use managed NGINX only when the selected AKS version still supports it and the user accepts a documented migration deadline.

AKS Automatic 1.36 and later can use application-routing Gateway API by default. Older Automatic clusters may have managed external NGINX. Inspect live resources and do not convert one model to another by assumption.

The chart-managed Ingress is NGINX-specific. For Gateway API, Application Gateway for Containers, Traefik, or another implementation, set `ingress.enabled: false` and express the two Phase routes with native resources.

## Public Gateway API path

For the current AKS-managed implementation, follow the official enablement guide and verify the `approuting-istio` `GatewayClass`. Use the current Azure DNS/Key Vault integration or a supported certificate controller; do not invent certificate material.

Disable the chart-managed Ingress:

```yaml
ingress:
  enabled: false

certManager:
  enabled: false
```

After a valid TLS Secret exists in the `phase` namespace, the routing contract is:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: phase-console
  namespace: phase
spec:
  gatewayClassName: approuting-istio
  listeners:
    - name: https
      hostname: phase.example.com
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: phase-console-tls
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: phase-console
  namespace: phase
spec:
  parentRefs:
    - name: phase-console
  hostnames:
    - phase.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /service
      backendRefs:
        - name: phase-console-backend
          port: 8000
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: phase-console-frontend
          port: 3000
```

Use the final hostname, render the selected Phase release to confirm Service names/ports, and server-side dry-run the resources. Preserve `/service`; do not rewrite it.

Gateway API does not make an NGINX source-range annotation portable. Use a reviewed controller-native/WAF/network restriction. If no bootstrap restriction is available, establish and test authentication before publishing DNS or attaching the public route.

## Managed NGINX compatibility path

For a new Standard-provisioned cluster, select `External` during `az aks create`. For an existing Standard cluster without application routing:

```bash
az aks approuting enable \
  --resource-group <resource-group> \
  --name <cluster> \
  --nginx External
```

If an existing controller is already external, do not issue a redundant update. If an AKS Automatic cluster has this older managed external NGINX controller, preserve it.

Do not select this for a new production deployment without recording the current Microsoft support deadline and a migration owner.

Discover the class and Service rather than assuming names:

```bash
kubectl get ingressclass
kubectl -n app-routing-system get deployment,pods,services -o wide
```

Point the final DNS record to the reported public IP/FQDN. Validate multiple public resolvers before ACME HTTP-01 or onboarding.

Install a currently supported cert-manager release and create an issuer using the actual ingress class:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: "<operations-email>"
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            ingressClassName: webapprouting.kubernetes.azure.com
```

Use a trusted bootstrap CIDR on the Phase Ingress. Have the user determine their public egress from the actual onboarding workstation:

```bash
curl -4 https://ifconfig.me
```

Append `/32`, or use an approved routed corporate/VPN/VNet range. Never use `0.0.0.0/0` as an example restriction.

```yaml
ingress:
  enabled: true
  className: "webapprouting.kubernetes.azure.com"
  host: "phase.example.com"
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: "<trusted-bootstrap-cidr>"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"

certManager:
  enabled: true
  issuerName: "letsencrypt-prod"
```

Render the selected chart to ensure it does not emit a conflicting duplicate annotation. Validate an allowed source receives the application and an untrusted source receives `403` before onboarding.

## Private NGINX path

### New Standard cluster

For a dedicated new Standard cluster, setting the default controller to `Internal` at cluster creation is the simplest validated private path. Confirm its Service receives an RFC1918 address and no public frontend.

### Existing Standard or AKS Automatic with managed NGINX

Do not flip the default controller from external to internal. Create a second internal controller with a distinct class:

```yaml
apiVersion: approuting.kubernetes.azure.com/v1alpha1
kind: NginxIngressController
metadata:
  name: nginx-internal
spec:
  ingressClassName: nginx-internal
  controllerNamePrefix: nginx-internal
  loadBalancerAnnotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
```

```bash
kubectl apply --dry-run=server -f nginx-internal-controller.yaml
kubectl apply -f nginx-internal-controller.yaml
kubectl -n app-routing-system get services -o wide
kubectl get ingressclass nginx-internal
```

Use the actual generated internal Service name in any Tailscale bridge. An Ingress backend Service must be in the same namespace as the Ingress, so the bridge belongs in `app-routing-system` when it targets that managed NGINX Service.

On Automatic, this separate-controller pattern preserves the load balancer that NAP expects. Never compensate for a Pending Tailscale operator by tolerating hosted/system taints; fix workload-node provisioning.

An internal Azure Load Balancer is not required if the customer already maintains a suitable ClusterIP ingress controller for the Tailscale bridge. Reuse a maintained controller rather than adding one solely by habit.

## Bring-your-own controller or NGINX-free path

Chart `1.0.2` emits NGINX regex and rewrite annotations. If the selected controller is Traefik, Gateway API, Application Gateway for Containers, or another implementation, disable chart ingress:

```yaml
ingress:
  enabled: false

certManager:
  enabled: false
```

Create controller-native routing. Current Phase accepts `/service` directly, so preserve the prefix:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: phase-console
  namespace: phase
spec:
  ingressClassName: "<controller-class>"
  tls:
    - hosts:
        - phase.example.com
      secretName: phase-console-tls
  rules:
    - host: phase.example.com
      http:
        paths:
          - path: /service
            pathType: Prefix
            backend:
              service:
                name: phase-console-backend
                port:
                  number: 8000
          - path: /
            pathType: Prefix
            backend:
              service:
                name: phase-console-frontend
                port:
                  number: 3000
```

Do not add a `/service` rewrite. Add the controller's equivalent TLS, request-size, timeout, source restriction, and trusted-proxy configuration only when needed.

For Gateway API, express the same two prefix routes with the current controller's `Gateway`/`HTTPRoute` resources. Verify the implementation supports required TLS and client-IP behavior; do not mechanically translate NGINX annotations.

## DNS and TLS validation

```bash
dig @8.8.8.8 phase.example.com +short
dig @1.1.1.1 phase.example.com +short
dig @9.9.9.9 phase.example.com +short
curl --fail --show-error --head https://phase.example.com/api/health
openssl s_client -connect phase.example.com:443 -servername phase.example.com </dev/null
```

Wait for consistent DNS and a valid certificate. Do not bypass certificate verification in acceptance tests.

## Exposure acceptance

Before declaring ingress complete, prove:

- DNS resolves through the intended public/private mechanism.
- TLS certificate hostname and chain validate.
- `/api/health` reaches frontend and `/service/health/` reaches backend.
- HTTP redirects to HTTPS where HTTP exists.
- an untrusted bootstrap source is denied for public Azure ingress.
- no unintended Azure public LoadBalancer or public Ingress route exposes Phase.
- a new audit event records the expected client IP.
