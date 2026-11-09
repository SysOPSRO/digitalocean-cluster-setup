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

For the OCI move-stage cluster use `environments/oci-move-stage.env.example`.

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
rbac-manager            apps/rbac                                           manager-1.0.0
dex-k8s-authenticator   skm/dex-k8s-authenticator                                   0.0.2
kube-oidc-proxy         src/kube-oidc-proxy/deploy/charts/kube-oidc-proxy           0.3.2
dex                     dex/dex                                                    0.13.0
cert-manager            jetstack/cert-manager                                     v1.11.0
ingress-nginx           ingress-nginx/ingress-nginx                                 4.5.2
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

If `USE_EXTERNAL_SECRETS=false`, create these secrets manually before the first `apply`.

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

### OCI Vault credentials (only if USE_EXTERNAL_SECRETS=true)

```sh
kubectl create secret generic oci-credentials -n external-secrets \
  --from-file=privateKey=path/to/oci_api_key.pem \
  --from-literal=fingerprint=<OCI_API_KEY_FINGERPRINT>
```

### Notes for existing clusters

- Set `INSTALL_INGRESS_NGINX=false` if ingress-nginx is already installed (by
  Terraform, a previous run or anything else); set `INGRESS_CLASS` to match your
  existing ingress class (`nginx` or `nginx-internal`). With the current
  helmfile this **skips** the release — it never uninstalls it.
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
outside this repo (e.g. Terraform-owned on OCI, or a pre-existing cert-manager)
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
- Committed templates: `environments/default.env.example` and
  `environments/oci-move-stage.env.example` (no secrets).
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

