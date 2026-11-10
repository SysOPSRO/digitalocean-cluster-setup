# digitalocean-cluster-setup
Setup needed components on a digitalocean cluster, after downloading the admin kube config.

## Requirements:
0. Cluster nodes must be `linux/amd64` (mixed arm64 nodes are not supported by all images)
1. DigitalOcean K8S cluster created and config downloaded
2. ZeroSSL account and EAB Credentials for ACME Clients (only when `CERT_PROVIDER=zerossl`)
3. Google OAuth and OAuth 2.0 Client credentials configured
4. Locally: `helm`, `helmfile`, the `helm-diff` plugin and `kubectl`

## How to set this up

1. Download config and save it to `~/.kube/new-cluster`
2. Use the config to access the cluster:

`export KUBECONFIG=~/.kube/new-cluster`

3. Create your environment file from the committed example. Real env files are
   **git-ignored** (they contain secrets) — never commit them.

```
cp environments/default.env.example environments/default.env
$EDITOR environments/default.env
```

For other clusters copy the example and adjust `CLUSTER_FQDN`, `LB_PROVIDER`, `DNS_PROVIDER` and the LB fields.

4. Source the env file (optional — the wrapper sources it for you):

`. environments/default.env`

5. Deploy components:

`./scripts/helmfile.sh --env-file environments/default.env apply`

Do **not** use `helmfile sync` / `helmfile destroy` directly (see
[Safety: apply, never sync](#safety-apply-never-sync)).

6. Watch for the load balancer ip so you add it to your DNS:

`k get services -n ingress-nginx -o wide -w ingress-nginx-controller`

7. When External IP has data, create your dns records like

```
clustername.domain.org. 600 IN A external.ip.address.here
*.clustername 600 IN CNAME clustername.domain.org.
```

8. At the end of the deploy you should see something alike (only the releases
   enabled in your env file are shown; a component already installed elsewhere
   is absent, not removed):

```
UPDATED RELEASES:
NAME                    CHART                                                     VERSION
zerossl-issuer          apps/zerossl-issuer                                         1.0.0
cert-manager-issuer     apps/cert-manager-issuer                                    1.0.0
reflector               emberstack/reflector                                       10.0.70
star-certificates       apps/star-certificates                                      1.0.0
external-secrets-store  apps/external-secrets-store                                 1.0.0
rbac-manager            apps/rbac                                           manager-1.0.0
dex-k8s-authenticator   skm/dex-k8s-authenticator                                   0.0.2
kube-oidc-proxy         src/kube-oidc-proxy/deploy/charts/kube-oidc-proxy           0.3.2
dex                     dex/dex                                                    0.13.0
cert-manager            jetstack/cert-manager                                     v1.11.0
ingress-nginx           ingress-nginx/ingress-nginx                                 4.10.0
nginx-internal          ingress-nginx/ingress-nginx                                 4.10.0
```


Do some checks to see everything is good:

```
  ~/ kubectl get clusterissuers.cert-manager.io                                                                                                                                                                                                                        [23/03/2 13:04:42]
NAME           READY   AGE
zerossl-prod   True    5m
  ~/ kubectl get secrets --all-namespaces | egrep tls                                                                                                                                                                                                                  [23/03/2 13:04:57]
dex               dex-k8s-authenticator-tls                        kubernetes.io/tls                     2      5m
dex               dex-tls                                          kubernetes.io/tls                     2      5m
kube-oidc-proxy   kube-oidc-proxy-tls                              kubernetes.io/tls                     2      5m
kube-oidc-proxy   oidcproxy-tls                                    kubernetes.io/tls                     2      5m
  ~/ kubectl get ing --all-namespaces
NAMESPACE         NAME                    CLASS    HOSTS                          ADDRESS             PORTS     AGE
dex               dex                     <none>   dex.cluster.domain.org         your.ip.addr.here   80, 443   5m
dex               dex-k8s-authenticator   <none>   login.cluster.domain.org       your.ip.addr.here   80, 443   5m
kube-oidc-proxy   kube-oidc-proxy         <none>   oidcproxy.cluster.domain.org   your.ip.addr.here   80, 443   5m
```

## Manual secrets (when not using external-secrets)

If `ENABLE_EXTERNAL_SECRETS=false`, create these secrets manually before the first `apply`.

### DNS provider secret (cert-manager DNS-01)

```sh
# AWS Route53
kubectl create secret generic dns-credentials -n cert-manager \
  --from-literal=aws-secret-access-key=<AWS_SECRET_ACCESS_KEY>

# Cloudflare
kubectl create secret generic dns-credentials -n cert-manager \
  --from-literal=cloudflare-api-token=<CF_API_TOKEN>

# PowerDNS
kubectl create secret generic dns-credentials -n cert-manager \
  --from-literal=pdns-api-key=<PDNS_API_KEY>

# Technitium
kubectl create secret generic dns-credentials -n cert-manager \
  --from-literal=technitium-token=<TECHNITIUM_TOKEN>
```

### Existing wildcard TLS certificate

If `EXISTING_WILDCARD_CERT_SECRET` is set, create the TLS secret in the relevant namespaces:

```sh
kubectl create secret tls <SECRET_NAME> -n <NAMESPACE> \
  --cert=path/to/fullchain.pem --key=path/to/privkey.pem
```

### External Secrets credentials (only if ENABLE_EXTERNAL_SECRETS=true)

OCI (keys `privateKey` and `fingerprint`):

```sh
kubectl create secret generic oci-credentials -n external-secrets \
  --from-file=privateKey=path/to/oci_api_key.pem \
  --from-literal=fingerprint=<OCI_API_KEY_FINGERPRINT>
```

AWS with `EXTERNAL_SECRETS_AWS_AUTH=secretRef` (keys `access-key-id` and
`secret-access-key`; the key names are configurable):

```sh
kubectl create secret generic aws-credentials -n external-secrets \
  --from-literal=access-key-id=<AWS_ACCESS_KEY_ID> \
  --from-literal=secret-access-key=<AWS_SECRET_ACCESS_KEY>
```

### Notes for existing clusters

- Set `INSTALL_INGRESS_NGINX=false` if ingress-nginx is already installed (by
  Terraform, a previous run or anything else); set `INGRESS_CLASS` to match your
  existing ingress class (`nginx`). With the current helmfile this **skips** the
  release — it never uninstalls it.
- Set `INSTALL_INGRESS_NGINX_INTERNAL=false` if the internal controller is
  managed elsewhere; it defaults to the `INSTALL_INGRESS_NGINX` value.
- Set `CERT_MANAGER_ENABLED=false` if cert-manager is already installed. Again:
  this skips it, it does not remove it. The OIDC serving certificate can still
  be managed by that existing cert-manager (see
  [kube-oidc-proxy serving certificate](#kube-oidc-proxy-serving-certificate)).
- external-dns and external-secrets are assumed already installed; this repo
  does not manage them.

## Safety: apply, never sync

**The problem.** In helmfile, `installed: false` means *uninstall the release*,
not *skip it*. The previous version of `helmfile.yaml` gated `ingress-nginx`,
`cert-manager` and `zerossl-issuer` with
`installed: <env flag expression>`. On clusters where a component is installed
outside this repo (e.g. managed by Terraform, or a pre-existing cert-manager)
the flag is `false`, so `helmfile sync` **deleted** the release instead of
leaving it alone.

**The fix.**

- Optional releases are wrapped in a Go-template conditional, so when the flag
  is false the release is absent from the state — helmfile cannot see it, let
  alone delete it.
- `scripts/helmfile.sh` refuses `destroy` and `delete`, and refuses `sync`
  unless `HELMFILE_ALLOW_SYNC=true`. Use `apply` (only upgrades releases whose
  rendered manifests changed).
- To intentionally remove something, do it explicitly:
  `helm uninstall <release> -n <namespace>`.

## Environment files

- `environments/*.env` are **git-ignored** (`.gitignore`: `environments/*` with
  an exception for `*.env.example`).
- Committed templates: `environments/default.env.example` (no secrets).
  Copy it to `environments/<name>.env` and adjust per cluster.
- Existing env files are never modified by this repo's tooling; they are only
  sourced.
- `helmfile-*/` output snapshots are git-ignored too — rendered values can
  contain secrets (e.g. the dex Google `clientSecret`).

## Wrapper usage

```sh
./scripts/helmfile.sh [--env-file PATH] [--kubeconfig PATH] [--context NAME] \
                      [--selector LABEL] [--tls-provider MODE] <action>
```

Actions: `check`, `diff`, `apply`, `template`, `list`, `build`, `deps`,
`status`, `lint`.

```sh
E=environments/default.env

./scripts/helmfile.sh --env-file "$E" check    # validate env + cluster, no changes
./scripts/helmfile.sh --env-file "$E" list     # releases that are in the state
./scripts/helmfile.sh --env-file "$E" diff     # read-only diff
./scripts/helmfile.sh --env-file "$E" apply    # apply (after the diff is understood)
```

`diff` exits `2` when there are differences (helm-diff behaviour); this is
expected, not an error. Requirements: `helm`, `helmfile`, the `helm-diff`
plugin and `kubectl`.

## kube-oidc-proxy serving certificate

The upstream chart renders `kube-oidc-proxy-tls` with
`genCA`/`genSignedCert`, which generate a **new random certificate on every
render**. Consequences: `helmfile diff` is permanently dirty and every `apply`
rotates the certificate (plus the `postupgrade` restart).

This repo keeps the upstream chart untouched (`src/kube-oidc-proxy` is a git
submodule) and controls the certificate through
`KUBE_OIDC_PROXY_TLS_PROVIDER`:

| Value | Behaviour |
|---|---|
| `auto` (**default**) | Secret exists → `adopt`; else cert-manager CRDs exist → `cert-manager`; else `chart`. Never rotates an existing certificate. |
| `adopt` | Reuse the existing Secret untouched. The chart renders neither the Secret nor a Certificate. |
| `cert-manager` | Issue/renew it with cert-manager, using the local `apps/kube-oidc-proxy-tls` chart (`SelfSigned` Issuer + `Certificate`). |
| `chart` | Upstream behaviour: random self-signed cert on every render. |

`scripts/helmfile.sh` resolves `auto` **at run time** (it inspects the Secret
and the `certificates.cert-manager.io` CRD) and exports
`KUBE_OIDC_PROXY_TLS_MODE`, which `helmfile.yaml` uses to include the
`kube-oidc-proxy-tls` release. `--tls-provider` overrides the env file.

### cert-manager: pre-existing or installed by this repo

- **Already in the cluster** (installed by Terraform, another chart, manually…):
  set `CERT_MANAGER_ENABLED=false` and
  `KUBE_OIDC_PROXY_TLS_PROVIDER=cert-manager` (or leave `auto`, which detects
  the CRDs when no Secret exists yet). Nothing installs/upgrades cert-manager.
- **Installed by this repo** (`CERT_MANAGER_ENABLED=true`): the
  `kube-oidc-proxy-tls` release carries `needs: [cert-manager]`, so the CRDs
  exist before the `Certificate` is submitted. If the CRDs are still missing at
  the start of that first run, the wrapper falls back to `chart` for that run
  (otherwise `diff` would fail on an unknown CRD) and prints a warning; run
  again with `cert-manager` to switch.

The certificate is only used on the ingress-nginx → pod hop
(`backend-protocol: HTTPS`, upstream verification off by default). Clients
validate the **ingress** certificate, so changing this one cannot break
existing kubeconfigs.

## ZeroSSL issuer

`zerossl-issuer` is included only when **all three** are set:
`CERT_PROVIDER=zerossl`, `ZEROSSL_EAB`, `ZEROSSL_KID`. `CERT_MANAGER_ENABLED`
only controls whether this repo installs cert-manager; the issuer can target a
pre-existing cert-manager.


## Ingress: public + private controllers

Two independent releases (same chart, different class/namespace):

| | public | private |
|---|---|---|
| release | `ingress-nginx` | **`nginx-internal`** |
| namespace | `ingress-nginx` | **`ingress-nginx-internal`** |
| ingress class | `nginx` (default) | `nginx-internal` (non-default, by name) |
| controller-class | `k8s.io/ingress-nginx` | `k8s.io/ingress-nginx-internal` |
| workload | `DaemonSet` (default) or `Deployment` | always `Deployment` |
| replicas | one per node; `INGRESS_REPLICAS` switches to Deployment | `INTERNAL_INGRESS_REPLICAS` (default 2) |
| externalTrafficPolicy | `Local` (DaemonSet) / `Cluster` (Deployment) | `Cluster` |
| service | LB / NodePort per `LB_PROVIDER` | internal LB / NodePort per `LB_PROVIDER` |
| ServiceMonitor | `INGRESS_METRICS_SERVICEMONITOR` | same |

Switches: `INSTALL_INGRESS_NGINX`, `INSTALL_INGRESS_NGINX_INTERNAL`
(defaults to the public value).

### Why DaemonSet by default

With one pod per node and `externalTrafficPolicy: Local`, every LB backend has
a local pod, so client IPs are preserved without relying on a cloud-specific
PROXY protocol, and no replica count has to track the node count. Setting
`INGRESS_REPLICAS` forces a `Deployment` with that many replicas (and
`externalTrafficPolicy: Cluster`); the private controller is always a
Deployment.

### LB providers (`LB_PROVIDER`, independent of `DNS_PROVIDER`)

`LB_PROVIDER` has **no default**. When it is empty the controllers are still
deployed, but the Services get no provider annotations (cloud default type).
The internal controller falls back to `NodePort` in that case.

| `LB_PROVIDER` | public LB | private LB |
|---|---|---|
| `aws` | NLB (`aws-load-balancer-type=nlb`, scheme internet-facing) | NLB internal (scheme `internal` + `aws-load-balancer-internal`) |
| `oci` | NLB (`is-preserve-source`, `PUBLIC_LB_SUBNET_OCID`, `PUBLIC_LB_NSG_OCIDS`, `PUBLIC_LB_RESERVED_IP`) | classic LB internal (`INTERNAL_LB_SUBNET_OCID`, flexible `INTERNAL_LB_SHAPE_MIN/MAX`) |
| `hetzner` | hcloud LB (`HETZNER_LB_TYPE/LOCATION/NAME`, PROXY protocol) | `NodePort`; `HETZNER_INTERNAL_LB=true` requests an hcloud LB with `use-private-ip` |
| `digitalocean` | DO LB (`DO_LB_SIZE`, `DO_LB_NAME`, PROXY protocol) | `NodePort` (DO has no private LB) |
| `contabo` | `NodePort` | `NodePort` |
| `metal` | `NodePort` (MetalLB comes in a later step) | `NodePort` |

### Ingress status and default TLS certificate

- `PUBLIC_LB_PUBLISH_STATUS_ADDRESS` / `INTERNAL_LB_PUBLISH_STATUS_ADDRESS`
  pin `--publish-status-address` and disable `publishService`. The value can be
  an IP **or** an FQDN: an FQDN is written as `status.loadBalancer.ingress[].hostname`
  and external-dns turns it into a CNAME (useful on OCI, where the NLB reports
  both a public and an internal IP).
- When the star certificates are enabled, both controllers get
  `--default-ssl-certificate=<ns>/star-<main-domain>-tls` (the main domain's
  wildcard secret, mirrored by Reflector).

All managed LBs are **requested from annotations** (`Service type=LoadBalancer`);
nothing is attached to a pre-existing LB by OCID. On `oci` and `aws` the NLB
preserves the source address at L4; on `hetzner`/`digitalocean` the LB is a TCP
proxy, so PROXY protocol is enabled on both sides.

### Real client IP / CDN ranges

`apps/ingress-nginx/values.yaml.gotmpl` holds four separate lists —
`cloudflareIPv4`, `cloudflareIPv6`, `cloudfrontIPv4`, `cloudfrontIPv6` — and
`proxy-real-ip-cidr` defaults to their concatenation. Override the whole list
with `PROXY_REAL_IP_CIDR` (comma separated). Keep the lists in sync with:

- Cloudflare: <https://www.cloudflare.com/ips-v4>, <https://www.cloudflare.com/ips-v6>
- CloudFront: <https://ip-ranges.amazonaws.com/ip-ranges.json> (`CLOUDFRONT_ORIGIN_FACING`)

Sources not matching these ranges keep their real address (the NLB preserves
it); only CDN edges are trusted for `X-Forwarded-For`.

## DNS-01 ClusterIssuer (`DNS_PROVIDER`)

`apps/cert-manager-issuer` creates one `ClusterIssuer` (default name
`prod-issuer`) with a DNS-01 solver for:

| `DNS_PROVIDER` | solver |
|---|---|
| `aws` | `route53` (`AWS_REGION`/`ROUTE53_REGION`, keys from `DNS_SECRET_NAME`) |
| `cloudflare` | `cloudflare` (`apiTokenSecretRef`) |
| `powerdns` | `webhook` (`acme.sysops.ro` / `pdns`, host `DNS_ENDPOINT`) |
| `technitium` | `webhook` (host `DNS_ENDPOINT`) |
| `oci` | `webhook` — requires `cert-manager-webhook-oci` installed outside this repo; needs `OCI_DNS_COMPARTMENT_OCID`, optional `OCI_DNS_PROFILE_SECRET_NAME`, and `OCI_DNS_WEBHOOK_GROUP` matching the installed webhook |

`ACME_EMAIL` is **required** for the issuer (used for both Let's Encrypt and
ZeroSSL). When `CERT_PROVIDER=zerossl`, `ZEROSSL_EAB` and `ZEROSSL_KID` are
required too: ZeroSSL cannot register an ACME account without external account
binding. The chart creates its own `<issuer>-eab` Secret, so it does not collide
with the dedicated `zerossl-issuer` chart's `zerossl-eab`.

`CERT_MANAGER_ISSUER_ENABLED=auto` (default) creates it only when the
cert-manager CRDs already exist (installed by this repo or by anything else).
`DNS_ZONES` (space separated) restricts the solver to those zones.

## Star certificates + Reflector

When `STAR_MAIN_DOMAIN` is set (`INSTALL_STAR_CERT=auto`), the repo creates one
wildcard `Certificate` **per domain** — not one certificate containing all
domains:

| variable | effect |
|---|---|
| `STAR_MAIN_DOMAIN` | `<domain>` + `*.<domain>`; its secret is the default TLS secret of both controllers |
| `STAR_EXTRA_DOMAINS` | one certificate per extra domain (`<domain>` + `*.<domain>`) |
| `STAR_CERT_NAMESPACES` | Reflector auto-reflection/allow-list; empty = **all** namespaces |
| `INSTALL_REFLECTOR` | `auto` (default) installs `emberstack/reflector` 10.0.70 when star certs are enabled |

Secret names: `star-<domain-with-dashes>-tls`. Certificates live in the
`cert-manager` namespace and carry the Reflector annotations
(`reflection-allowed`, `reflection-auto-enabled`, plus the namespace lists when
`STAR_CERT_NAMESPACES` is set), so every namespace gets a copy — including the
two ingress namespaces, which is what `default-ssl-certificate` points at.

`INSTALL_STAR_CERT=true` requires the ClusterIssuer and Reflector to be enabled;
the wrapper refuses to run otherwise.

## External Secrets

`ENABLE_EXTERNAL_SECRETS=true` creates a `ClusterSecretStore` (External Secrets
Operator CRDs must exist; the operator is not installed here):

| variable | effect |
|---|---|
| `EXTERNAL_SECRETS_PROVIDER` | `oci` (OCI Vault) or `aws` (Secrets Manager) |
| `EXTERNAL_SECRETS_STORE_NAME` | store name; defaults to `oci-vault-store` / `aws-secrets-manager` |
| `EXTERNAL_SECRETS_AUTH_SECRET_NAME` | Secret with the credentials; defaults to `oci-credentials` / `aws-credentials` |
| `OCI_VAULT_OCID`, `OCI_VAULT_REGION`, `OCI_VAULT_USER_OCID`, `OCI_VAULT_TENANCY_OCID` | OCI API-key auth |
| `AWS_SECRETS_REGION` | AWS region |
| `EXTERNAL_SECRETS_AWS_AUTH` | `secretRef` (access key id + secret key in the auth Secret) or `jwt` (IRSA / EKS Pod Identity service account) |

For OCI the auth Secret needs `privateKey` and `fingerprint` keys; for AWS
`secretRef` it needs `access-key-id` and `secret-access-key` (configurable via
`EXTERNAL_SECRETS_AWS_ACCESS_KEY_ID_KEY` / `..._SECRET_ACCESS_KEY_KEY`).

## Provider credentials helper

`scripts/provider-credentials.sh` creates the credential Secrets used by the
stack / the provider CCM. It verifies that the CLI exists and that the requested
profile is configured, then applies the Secret idempotently (nothing is printed
or written to disk).

| provider | Secret (keys) | namespace | source |
|---|---|---|---|
| `aws` | `aws-credentials` (`access-key-id`, `secret-access-key`) | `external-secrets` | AWS CLI profile (`--profile` / `AWS_PROFILE`) |
| `oci` | `oci-credentials` (`privateKey`, `fingerprint`, `tenancy`, `user`, `region`) | `external-secrets` | OCI CLI profile from `~/.oci/config` |
| `do` / `digitalocean` | `digitalocean` (`access-token`) | `kube-system` | `DIGITALOCEAN_TOKEN` |
| `hetzner` | `hcloud` (`hcloud`) | `kube-system` | `HCLOUD_TOKEN` |
| `contabo` | — | — | no LB/CCM: NodePort only |

```sh
./scripts/provider-credentials.sh --provider aws --profile wearemove
./scripts/provider-credentials.sh --provider oci --profile sysops
DIGITALOCEAN_TOKEN=... ./scripts/provider-credentials.sh --provider do
HCLOUD_TOKEN=...     ./scripts/provider-credentials.sh --provider hetzner
```

`--namespace`, `--context` and `--dry-run` are also supported.

## Metal / Contabo

`metal` and `contabo` currently expose both controllers as `NodePort`
(no LB). MetalLB (IPAddressPool / L2Advertisement / BGP with MikroTik) is a
follow-up change; until then the node ports must be routed by the network
(MikroTik/HAProxy/keepalived) or reached over VPN.
