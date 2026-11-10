#!/usr/bin/env bash
#
# helmfile.sh — safe wrapper around `helmfile` for this repository.
#
#   * loads an environment file from environments/ (shell `export` format)
#   * computes the flags that must not rely on `installed:` in helmfile.yaml
#     (ZEROSSL_ISSUER_ENABLED, kube-oidc-proxy TLS mode)
#   * refuses destructive helmfile subcommands (destroy/delete, and sync unless
#     explicitly allowed)
#   * optionally guards the kube context
#
# Usage:
#   ./scripts/helmfile.sh [options] <action> [helmfile args...]
#
#   --env-file PATH     environment file to source
#                       (default: $ENV_FILE, else environments/default.env)
#   --kubeconfig PATH   kubeconfig to use (default: $KUBECONFIG or ~/.kube/config)
#   --context NAME      expected current-context (default: $EXPECTED_CONTEXT)
#   --selector SEL      helmfile label selector (default: none)
#   --no-selector       do not pass --selector
#   --tls-provider V    override KUBE_OIDC_PROXY_TLS_PROVIDER (auto|adopt|cert-manager|chart)
#   --                  pass the rest verbatim to helmfile
#
# Actions: check | diff | apply | template | list | build | deps | status | lint
#
# Examples:
#   ./scripts/helmfile.sh --env-file environments/default.env check
#   ./scripts/helmfile.sh --env-file environments/default.env diff
#   ./scripts/helmfile.sh --env-file environments/default.env apply
#
# Environment fallbacks: ENV_FILE, KUBECONFIG, EXPECTED_CONTEXT,
# HELMFILE_SELECTOR, HELMFILE_EXTRA_ARGS, HELMFILE_BINARY,
# HELMFILE_ALLOW_SYNC=true (to permit `sync`).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

HELMFILE_BINARY="${HELMFILE_BINARY:-helmfile}"
ENV_FILE="${ENV_FILE:-}"
KUBECONFIG_FILE="${KUBECONFIG:-}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-}"
SELECTOR="${HELMFILE_SELECTOR:-}"
ACTION=""
HELMFILE_ARGS=()
CLI_TLS_PROVIDER=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

expand_home() {
  # SC2088: literal "~" coming from flags/Terraform values, expanded here
  # shellcheck disable=SC2088
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------- arguments --
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      [[ $# -ge 2 ]] || die "--env-file needs a value"
      ENV_FILE="$2"
      shift 2
      ;;
    --kubeconfig)
      [[ $# -ge 2 ]] || die "--kubeconfig needs a value"
      KUBECONFIG_FILE="$2"
      shift 2
      ;;
    --context)
      [[ $# -ge 2 ]] || die "--context needs a value"
      EXPECTED_CONTEXT="$2"
      shift 2
      ;;
    --selector)
      [[ $# -ge 2 ]] || die "--selector needs a value"
      SELECTOR="$2"
      shift 2
      ;;
    --no-selector)
      SELECTOR=""
      shift
      ;;
    --tls-provider)
      [[ $# -ge 2 ]] || die "--tls-provider needs a value"
      CLI_TLS_PROVIDER="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      HELMFILE_ARGS+=("$@")
      break
      ;;
    -*)
      die "unknown option: $1 (use -- before helmfile args)"
      ;;
    *)
      ACTION="$1"
      shift
      HELMFILE_ARGS+=("$@")
      break
      ;;
  esac
done

[[ -n "$ACTION" ]] || { usage; exit 2; }

case "$ACTION" in
  destroy|delete)
    die "refusing '$ACTION': removing releases is never implicit. Use 'helm uninstall' deliberately if that is really what you want."
    ;;
  sync)
    [[ "${HELMFILE_ALLOW_SYNC:-false}" == "true" ]] || die "refusing 'sync': use 'apply' (it only upgrades releases that changed). Set HELMFILE_ALLOW_SYNC=true to override."
    ;;
  check|diff|apply|template|list|build|deps|status|lint)
    ;;
  *)
    die "unsupported action '$ACTION' (allowed: check diff apply template list build deps status lint)"
    ;;
esac

# ------------------------------------------------------------ environment -----
if [[ -z "$ENV_FILE" && -f "${ROOT_DIR}/environments/default.env" ]]; then
  ENV_FILE="${ROOT_DIR}/environments/default.env"
fi
[[ -n "$ENV_FILE" ]] || die "no environment file: pass --env-file PATH (see environments/default.env.example)"
ENV_FILE="$(expand_home "$ENV_FILE")"
[[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"

set -a
# shellcheck disable=SC1090  # path comes from --env-file at runtime
. "$ENV_FILE"
set +a

export ENV_FILE
export HELMFILE_ROOT_DIR="$ROOT_DIR"

# --tls-provider wins over the value from the environment file.
if [[ -n "$CLI_TLS_PROVIDER" ]]; then
  export KUBE_OIDC_PROXY_TLS_PROVIDER="$CLI_TLS_PROVIDER"
fi

export CERT_PROVIDER="${CERT_PROVIDER:-letsencrypt}"
export INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
export NODE_ARCH="${NODE_ARCH:-amd64}"
export ZEROSSL_CA_PEM_FILE="${ZEROSSL_CA_PEM_FILE:-certs/zerossl-ca.pem}"
export LETS_ENCRYPT_CA_PEM_FILE="${LETS_ENCRYPT_CA_PEM_FILE:-certs/letsencrypt-ca.pem}"
export DEX_REPO="${DEX_REPO:-docker.io/mintel/dex-k8s-authenticator}"
export DEX_TAG="${DEX_TAG:-latest}"

require_var() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || die "$name is empty in $ENV_FILE"
}

for v in CLUSTER_FQDN DEX_NAME DEX_SECRET GOOG_ALLOWED_DOMAIN GOOG_CLIENT_ID \
         GOOG_CLIENT_SECRET RBAC_NAME RBAC_ADMIN_USERS; do
  require_var "$v"
done

# ZeroSSL issuer is included ONLY when the environment really configures it.
# CERT_MANAGER_ENABLED only decides whether THIS repo installs cert-manager.
if [[ "$CERT_PROVIDER" == "zerossl" && -n "${ZEROSSL_EAB:-}" && -n "${ZEROSSL_KID:-}" ]]; then
  export ZEROSSL_ISSUER_ENABLED=true
else
  export ZEROSSL_ISSUER_ENABLED=false
fi

# ----------------------------------------------------------------- cluster ----
if [[ -n "$KUBECONFIG_FILE" ]]; then
  KUBECONFIG_FILE="$(expand_home "$KUBECONFIG_FILE")"
elif [[ -f "$HOME/.kube/config" ]]; then
  KUBECONFIG_FILE="$HOME/.kube/config"
fi

cluster_reachable=false
if [[ -n "$KUBECONFIG_FILE" && -f "$KUBECONFIG_FILE" ]]; then
  export KUBECONFIG="$KUBECONFIG_FILE"
  if kubectl get --raw=/version >/dev/null 2>&1; then
    cluster_reachable=true
  fi
fi

current_context=""
if [[ "$cluster_reachable" == "true" ]]; then
  current_context="$(kubectl config current-context 2>/dev/null || true)"
  if [[ -n "$EXPECTED_CONTEXT" && "$current_context" != "$EXPECTED_CONTEXT" ]]; then
    die "wrong cluster: current context is '$current_context', expected '$EXPECTED_CONTEXT' (kubeconfig: $KUBECONFIG)"
  fi
fi

# Actions that must talk to the cluster.
case "$ACTION" in
  check|diff|apply|status)
    [[ "$cluster_reachable" == "true" ]] || die "cluster not reachable with kubeconfig '${KUBECONFIG:-<none>}' (kubectl get --raw=/version failed)"
    ;;
esac

case "$current_context" in
  *eu-central-1*|*eks*|*amazonaws*)
    die "refusing to run against AWS-looking context '$current_context'"
    ;;
esac

# --------------------------------------------------------- kube-oidc TLS -----
# auto (default): never rotate an existing certificate.
#   secret exists            -> adopt
#   cert-manager CRDs exist  -> cert-manager
#   otherwise                -> chart
# Explicit values always win, except `cert-manager` when its CRDs are missing
# but this run installs cert-manager: then `chart` is used for this run (the
# next run can switch, otherwise diff would fail on unknown CRDs).
requested_tls="${KUBE_OIDC_PROXY_TLS_PROVIDER:-auto}"
export KUBE_OIDC_PROXY_SECRET_NAME="${KUBE_OIDC_PROXY_SECRET_NAME:-kube-oidc-proxy-tls}"

secret_exists() {
  [[ "$cluster_reachable" == "true" ]] || return 1
  kubectl get secret "$KUBE_OIDC_PROXY_SECRET_NAME" -n kube-oidc-proxy >/dev/null 2>&1
}

cert_manager_crds() {
  [[ "$cluster_reachable" == "true" ]] || return 1
  kubectl get crd certificates.cert-manager.io >/dev/null 2>&1
}

case "$requested_tls" in
  auto)
    if secret_exists; then
      KUBE_OIDC_PROXY_TLS_MODE=adopt
    elif cert_manager_crds; then
      KUBE_OIDC_PROXY_TLS_MODE=cert-manager
    else
      if [[ "$cluster_reachable" != "true" ]]; then
        echo "WARN: cluster not reachable; auto TLS mode falls back to 'chart' for this offline run." >&2
      fi
      KUBE_OIDC_PROXY_TLS_MODE=chart
    fi
    ;;
  adopt)
    if secret_exists; then
      KUBE_OIDC_PROXY_TLS_MODE=adopt
    else
      echo "WARN: KUBE_OIDC_PROXY_TLS_PROVIDER=adopt but Secret $KUBE_OIDC_PROXY_SECRET_NAME does not exist; falling back to a chart-generated certificate." >&2
      KUBE_OIDC_PROXY_TLS_MODE=chart
    fi
    ;;
  cert-manager)
    if cert_manager_crds; then
      KUBE_OIDC_PROXY_TLS_MODE=cert-manager
    elif [[ "${CERT_MANAGER_ENABLED:-false}" == "true" ]]; then
      echo "WARN: cert-manager CRDs are not present yet; CERT_MANAGER_ENABLED=true installs cert-manager in this run, so a chart-generated certificate is used now. Re-run to switch to cert-manager." >&2
      KUBE_OIDC_PROXY_TLS_MODE=chart
    else
      die "KUBE_OIDC_PROXY_TLS_PROVIDER=cert-manager but certificates.cert-manager.io is missing and CERT_MANAGER_ENABLED is not true."
    fi
    ;;
  chart)
    KUBE_OIDC_PROXY_TLS_MODE=chart
    ;;
  *)
    die "KUBE_OIDC_PROXY_TLS_PROVIDER must be auto|adopt|cert-manager|chart (got '$requested_tls')"
    ;;
esac
export KUBE_OIDC_PROXY_TLS_MODE

# ------------------------------------------------------------------ ingress --
# Optional: no default. With no value the chart deploys the Service with the
# cloud default type and NO provider annotations.
export LB_PROVIDER="${LB_PROVIDER:-}"
if [[ -n "$LB_PROVIDER" ]]; then
  case "$LB_PROVIDER" in
    aws|oci|hetzner|digitalocean|contabo|metal) ;;
    *) die "LB_PROVIDER must be aws|oci|hetzner|digitalocean|contabo|metal (got '$LB_PROVIDER')" ;;
  esac
else
  echo "WARN: LB_PROVIDER is empty — no load-balancer annotations will be added." >&2
fi

# OCI_INTERNAL_LB was replaced by LB_PROVIDER + the internal release.
if [[ -n "${OCI_INTERNAL_LB:-}" ]]; then
  echo "WARN: OCI_INTERNAL_LB is no longer used; set LB_PROVIDER=oci instead." >&2
fi

# The internal controller follows the public switch unless set explicitly.
export INSTALL_INGRESS_NGINX_INTERNAL="${INSTALL_INGRESS_NGINX_INTERNAL:-${INSTALL_INGRESS_NGINX:-true}}"
case "$INSTALL_INGRESS_NGINX_INTERNAL" in
  true|false) ;;
  *) die "INSTALL_INGRESS_NGINX_INTERNAL must be true or false (got '$INSTALL_INGRESS_NGINX_INTERNAL')" ;;
esac

# Public controller: DaemonSet by default; setting INGRESS_REPLICAS forces a
# Deployment with that replica count (DaemonSet ignores replicaCount).
export INGRESS_CONTROLLER_KIND="${INGRESS_CONTROLLER_KIND:-DaemonSet}"
if [[ -n "${INGRESS_REPLICAS:-}" ]]; then
  INGRESS_CONTROLLER_KIND=Deployment
fi
export INGRESS_CONTROLLER_KIND
case "$INGRESS_CONTROLLER_KIND" in
  DaemonSet|Deployment) ;;
  *) die "INGRESS_CONTROLLER_KIND must be DaemonSet or Deployment (got '$INGRESS_CONTROLLER_KIND')" ;;
esac
export INGRESS_REPLICAS="${INGRESS_REPLICAS:-1}"
export INTERNAL_INGRESS_REPLICAS="${INTERNAL_INGRESS_REPLICAS:-2}"

# OCI needs an explicit subnet for each NLB (public) / LB (internal).
if [[ "${INSTALL_INGRESS_NGINX:-true}" == "true" && "$LB_PROVIDER" == "oci" && -z "${PUBLIC_LB_SUBNET_OCID:-}" ]]; then
  die "INSTALL_INGRESS_NGINX=true with LB_PROVIDER=oci requires PUBLIC_LB_SUBNET_OCID"
fi
if [[ "$INSTALL_INGRESS_NGINX_INTERNAL" == "true" && "$LB_PROVIDER" == "oci" && -z "${INTERNAL_LB_SUBNET_OCID:-}" ]]; then
  die "INSTALL_INGRESS_NGINX_INTERNAL=true with LB_PROVIDER=oci requires INTERNAL_LB_SUBNET_OCID"
fi

# ServiceMonitor: `auto` (default) enables it only when the Prometheus
# operator CRDs are installed, so `helm apply` cannot fail on a missing CRD.
if [[ "${INGRESS_METRICS_SERVICEMONITOR:-auto}" == "auto" ]]; then
  if [[ "$cluster_reachable" == "true" ]] && kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    INGRESS_METRICS_SERVICEMONITOR=true
  else
    INGRESS_METRICS_SERVICEMONITOR=false
  fi
fi
export INGRESS_METRICS_SERVICEMONITOR
case "$INGRESS_METRICS_SERVICEMONITOR" in
  true|false) ;;
  *) die "INGRESS_METRICS_SERVICEMONITOR must be auto, true or false" ;;
esac

# ---------------------------------------------------------------------- dns --
export DNS_PROVIDER="${DNS_PROVIDER:-aws}"
case "$DNS_PROVIDER" in
  aws|oci|cloudflare|powerdns|technitium) ;;
  *) die "DNS_PROVIDER must be aws|oci|cloudflare|powerdns|technitium (got '$DNS_PROVIDER')" ;;
esac

# ClusterIssuer: `auto` (default) creates it only when cert-manager CRDs exist.
if [[ "${CERT_MANAGER_ISSUER_ENABLED:-auto}" == "auto" ]]; then
  if cert_manager_crds; then
    CERT_MANAGER_ISSUER_ENABLED=true
  else
    CERT_MANAGER_ISSUER_ENABLED=false
  fi
fi
export CERT_MANAGER_ISSUER_ENABLED
case "$CERT_MANAGER_ISSUER_ENABLED" in
  true|false) ;;
  *) die "CERT_MANAGER_ISSUER_ENABLED must be auto, true or false" ;;
esac

if [[ "$CERT_MANAGER_ISSUER_ENABLED" == "true" ]]; then
  # The issuer chart renders `email` with requiredEnv; fail early and clearly.
  [[ -n "${ACME_EMAIL:-}" ]] || die "ACME_EMAIL is required when the cert-manager ClusterIssuer is enabled (used for both Let's Encrypt and ZeroSSL)"
  if [[ "$CERT_PROVIDER" == "zerossl" ]]; then
    [[ -n "${ZEROSSL_EAB:-}" && -n "${ZEROSSL_KID:-}" ]] || die "CERT_PROVIDER=zerossl requires ZEROSSL_EAB and ZEROSSL_KID (ZeroSSL cannot register an ACME account without external account binding)"
  fi
fi

# ---------------------------------------------------------- star certificates --
# STAR_MAIN_DOMAIN drives the default: a wildcard Certificate per domain
# (main + STAR_EXTRA_DOMAINS), mirrored to all namespaces by Reflector.
if [[ "${INSTALL_STAR_CERT:-auto}" == "auto" ]]; then
  if [[ -n "${STAR_MAIN_DOMAIN:-}" ]]; then
    INSTALL_STAR_CERT=true
  else
    INSTALL_STAR_CERT=false
  fi
fi
export INSTALL_STAR_CERT
case "$INSTALL_STAR_CERT" in
  true|false) ;;
  *) die "INSTALL_STAR_CERT must be auto, true or false" ;;
esac

if [[ "${INSTALL_REFLECTOR:-auto}" == "auto" ]]; then
  if [[ "$INSTALL_STAR_CERT" == "true" ]]; then
    INSTALL_REFLECTOR=true
  else
    INSTALL_REFLECTOR=false
  fi
fi
export INSTALL_REFLECTOR

if [[ "$INSTALL_STAR_CERT" == "true" ]]; then
  [[ -n "${STAR_MAIN_DOMAIN:-}" ]] || die "INSTALL_STAR_CERT=true requires STAR_MAIN_DOMAIN"
  [[ "$CERT_MANAGER_ISSUER_ENABLED" == "true" ]] || die "INSTALL_STAR_CERT=true requires the cert-manager ClusterIssuer (CERT_MANAGER_ISSUER_ENABLED=true/auto with cert-manager CRDs)"
  [[ "$INSTALL_REFLECTOR" == "true" ]] || die "INSTALL_STAR_CERT=true requires INSTALL_REFLECTOR=true"
fi

# ---------------------------------------------------------- external secrets --
export ENABLE_EXTERNAL_SECRETS="${ENABLE_EXTERNAL_SECRETS:-false}"
case "$ENABLE_EXTERNAL_SECRETS" in
  true|false) ;;
  *) die "ENABLE_EXTERNAL_SECRETS must be true or false" ;;
esac
if [[ "$ENABLE_EXTERNAL_SECRETS" == "true" ]]; then
  export EXTERNAL_SECRETS_PROVIDER="${EXTERNAL_SECRETS_PROVIDER:-oci}"
  case "$EXTERNAL_SECRETS_PROVIDER" in
    oci)
      for v in OCI_VAULT_OCID OCI_VAULT_REGION OCI_VAULT_USER_OCID OCI_VAULT_TENANCY_OCID; do
        [[ -n "${!v:-}" ]] || die "$v is required for EXTERNAL_SECRETS_PROVIDER=oci"
      done
      ;;
    aws)
      [[ -n "${AWS_SECRETS_REGION:-${AWS_REGION:-}}" ]] || die "AWS_SECRETS_REGION (or AWS_REGION) is required for EXTERNAL_SECRETS_PROVIDER=aws"
      auth="${EXTERNAL_SECRETS_AWS_AUTH:-secretRef}"
      case "$auth" in secretRef|jwt) ;; *) die "EXTERNAL_SECRETS_AWS_AUTH must be secretRef or jwt" ;; esac
      ;;
    *)
      die "EXTERNAL_SECRETS_PROVIDER must be oci or aws (got '$EXTERNAL_SECRETS_PROVIDER')"
      ;;
  esac
fi

# ------------------------------------------------------------------- report --
echo "helmfile:"
echo "  env file       : $ENV_FILE"
echo "  kubeconfig     : ${KUBECONFIG:-<none>}"
echo "  context        : ${current_context:-<not reachable / not set>}"
echo "  selector       : ${SELECTOR:-<none>}"
echo "  action         : $ACTION"
echo "  LB_PROVIDER    : ${LB_PROVIDER:-<none>}"
echo "  ingress-nginx  : $([[ "${INSTALL_INGRESS_NGINX:-true}" == "true" ]] && echo install || echo skip) (kind=$INGRESS_CONTROLLER_KIND replicas=$INGRESS_REPLICAS)"
echo "  nginx-internal : $INSTALL_INGRESS_NGINX_INTERNAL (kind=Deployment replicas=$INTERNAL_INGRESS_REPLICAS)"
echo "  servicemonitor : $INGRESS_METRICS_SERVICEMONITOR"
echo "  cert-manager   : $([[ "${CERT_MANAGER_ENABLED:-false}" == "true" ]] && echo install || echo skip) (existing CRDs: $(cert_manager_crds && echo yes || echo no))"
echo "  dns provider   : $DNS_PROVIDER (clusterissuer: $CERT_MANAGER_ISSUER_ENABLED)"
echo "  star cert      : $INSTALL_STAR_CERT (main=${STAR_MAIN_DOMAIN:-<unset>} extras='${STAR_EXTRA_DOMAINS:-}')"
echo "  reflector      : $INSTALL_REFLECTOR"
echo "  ext. secrets   : $ENABLE_EXTERNAL_SECRETS${ENABLE_EXTERNAL_SECRETS:+ (${EXTERNAL_SECRETS_PROVIDER:-oci})}"
echo "  zerossl-issuer : $ZEROSSL_ISSUER_ENABLED (CERT_PROVIDER=$CERT_PROVIDER)"
echo "  oidc-proxy TLS : $KUBE_OIDC_PROXY_TLS_MODE (requested: $requested_tls)"

if [[ "$ACTION" == "check" ]]; then
  echo "check: OK"
  exit 0
fi

# ----------------------------------------------------------------- helmfile ---
cd "$ROOT_DIR"

cmd=("$HELMFILE_BINARY")
if [[ -n "${HELMFILE_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra=(${HELMFILE_EXTRA_ARGS})
  cmd+=("${extra[@]}")
fi
cmd+=(-f "$ROOT_DIR/helmfile.yaml")
cmd+=(--allow-no-matching-release)
if [[ -n "$SELECTOR" ]]; then
  cmd+=(--selector "$SELECTOR")
fi
cmd+=("$ACTION")
cmd+=("${HELMFILE_ARGS[@]}")

exec "${cmd[@]}"
