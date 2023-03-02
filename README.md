# digitalocean-cluster-setup
Setup needed components on a digitalocean cluster, after downloading the admin kube config.

## Requirements:
1. DigitalOcean K8S cluster created and config downloaded
2. ZeroSSL account and EAB Credentials for ACME Clients
3. Google OAuth and OAuth 2.0 Client credentials configured

## How to set this up

1. Download config and save it to `~/.kube/new-cluster`
2. Use the config to access the cluster:

`export KUBECONFIG=~/.kube/new-cluster`

3. Set your environment variables in the folder `environments`.

```
mkdir environments
cat > environments/default.env << EOF
export CLUSTER_FQDN=""
# set a name for the dex, to identify it. I set it as the subdomain pointing to the cluster itself.
export DEX_NAME=""
# random secret. ie pwgen -snc 24 1
export DEX_SECRET=""
#list of domains separated by space " "
export GOOG_ALLOWED_DOMAIN=""
# oauth settings here
export GOOG_CLIENT_ID=""
export GOOG_CLIENT_SECRET=""
export ZEROSSL_EAB=""
export ZEROSSL_EMAIL=""
export ZEROSSL_KID=""
# set a name to match the role and binding; subdomain pointing to the cluster should be fine
export RBAC_NAME=""
#list of admins separated by space " "
export RBAC_ADMIN_USERS=""
```

4. Source the env file

`. environments/default.env`

5. Deploy components:

`helm sync`

6. Watch for the load balancer ip so you add it to your DNS:

`k get services -n ingress-nginx -o wide -w ingress-nginx-controller`

7. When External IP has data, create your dns records like

```
clustername.domain.org. 600 IN A external.ip.address.here
*.clustername 600 IN CNAME clustername.domain.org.
```

8. At the end of the deploy you should see something alike:

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
