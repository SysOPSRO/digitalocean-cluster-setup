#!/usr/bin/env bash
#
# provider-credentials.sh — create the cloud-provider credential Secrets used
# by this repo (and by the provider's cloud-controller-manager where relevant).
#
#   provider   secret            namespace          consumer
#   --------   ---------------   ----------------   ------------------------------
#   aws        aws-credentials   external-secrets   External Secrets / DNS-01
#   oci        oci-credentials   external-secrets   External Secrets (OCI Vault)
#   do         digitalocean      kube-system        DigitalOcean CCM (token)
#   hetzner    hcloud            kube-system        Hetzner CCM (token)
#   contabo    —                 —                  no LB/CCM: NodePort only
#
# It verifies that the CLI exists and that the requested profile is configured,
# then creates/updates the Secret idempotently (kubectl apply).
#
# Usage:
#   ./scripts/provider-credentials.sh --provider aws --profile wearemove
#   ./scripts/provider-credentials.sh --provider oci --profile sysops
#   ./scripts/provider-credentials.sh --provider do          # DIGITALOCEAN_TOKEN
#   ./scripts/provider-credentials.sh --provider hetzner     # HCLOUD_TOKEN
#   ./scripts/provider-credentials.sh --provider contabo
#
# Options:
#   --provider  aws|oci|do|digitalocean|hetzner|contabo   (required)
#   --profile   CLI profile (aws/oci). Default: AWS_PROFILE / OCI_CLI_PROFILE
#   --namespace override the target namespace
#   --context   kube context (default: current)
#   --dry-run   print the manifests instead of applying them
#
# Credentials are never printed and never written to disk by this script.

set -euo pipefail

PROVIDER=""
PROFILE=""
NAMESPACE=""
KUBE_CONTEXT=""
DRY_RUN=false

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) [[ $# -ge 2 ]] || die "--provider needs a value"; PROVIDER="$2"; shift 2 ;;
    --profile)  [[ $# -ge 2 ]] || die "--profile needs a value";  PROFILE="$2";  shift 2 ;;
    --namespace) [[ $# -ge 2 ]] || die "--namespace needs a value"; NAMESPACE="$2"; shift 2 ;;
    --context)  [[ $# -ge 2 ]] || die "--context needs a value";  KUBE_CONTEXT="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$PROVIDER" ]] || { usage; exit 2; }

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

kubectl_args=()
[[ -n "$KUBE_CONTEXT" ]] && kubectl_args+=(--context "$KUBE_CONTEXT")

apply_secret() {
  local ns="$1" name="$2"
  shift 2
  # remaining args are passed to `kubectl create secret` (--from-literal/--from-file)
  if [[ "$DRY_RUN" == "true" ]]; then
    kubectl "${kubectl_args[@]+"${kubectl_args[@]}"}" create secret generic "$name" -n "$ns" "$@" --dry-run=client -o yaml
    return
  fi
  kubectl "${kubectl_args[@]+"${kubectl_args[@]}"}" create secret generic "$name" -n "$ns" "$@" \
    --dry-run=client -o yaml | kubectl "${kubectl_args[@]+"${kubectl_args[@]}"}" apply -f -
}

# ---------------------------------------------------------------- providers --
case "$PROVIDER" in
  aws)
    command -v aws >/dev/null 2>&1 || die "aws CLI not found"
    PROFILE="${PROFILE:-${AWS_PROFILE:-default}}"
    aws configure get aws_access_key_id --profile "$PROFILE" >/dev/null 2>&1 \
      || die "AWS profile '$PROFILE' is not configured (aws configure list-profiles)"
    access_key="$(aws configure get aws_access_key_id --profile "$PROFILE")"
    secret_key="$(aws configure get aws_secret_access_key --profile "$PROFILE")"
    [[ -n "$access_key" && -n "$secret_key" ]] || die "AWS profile '$PROFILE' has no static access keys (SSO/role profiles are not supported here)"
    ns="${NAMESPACE:-external-secrets}"
    echo "creating aws-credentials in $ns from AWS profile '$PROFILE'"
    apply_secret "$ns" aws-credentials \
      --from-literal=access-key-id="$access_key" \
      --from-literal=secret-access-key="$secret_key"
    ;;

  oci)
    command -v oci >/dev/null 2>&1 || die "oci CLI not found"
    PROFILE="${PROFILE:-${OCI_CLI_PROFILE:-DEFAULT}}"
    oci_config="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
    [[ -f "$oci_config" ]] || die "OCI config not found: $oci_config"
    grep -q "^\[${PROFILE}\]" "$oci_config" || die "OCI profile '$PROFILE' not found in $oci_config"
    oci_get() {
      awk -v section="$PROFILE" -v key="$1" '
        /^\[/ { in_section = ($0 == "[" section "]"); next }
        in_section && index($0, key "=") == 1 { sub("^" key "=", ""); print; exit }
      ' "$oci_config"
    }
    key_file="$(oci_get key_file)"
    fingerprint="$(oci_get fingerprint)"
    tenancy="$(oci_get tenancy)"
    user="$(oci_get user)"
    region="$(oci_get region)"
    [[ -n "$key_file" && -n "$fingerprint" ]] || die "OCI profile '$PROFILE' is missing key_file/fingerprint"
    key_file="${key_file/#\~/$HOME}"
    [[ -f "$key_file" ]] || die "OCI private key not found: $key_file"
    ns="${NAMESPACE:-external-secrets}"
    echo "creating oci-credentials in $ns from OCI profile '$PROFILE'"
    apply_secret "$ns" oci-credentials \
      --from-file=privateKey="$key_file" \
      --from-literal=fingerprint="$fingerprint" \
      --from-literal=tenancy="$tenancy" \
      --from-literal=user="$user" \
      --from-literal=region="$region"
    ;;

  do|digitalocean)
    command -v doctl >/dev/null 2>&1 || die "doctl not found"
    [[ -n "${DIGITALOCEAN_TOKEN:-}" ]] || die "DIGITALOCEAN_TOKEN is not set (doctl profiles do not expose the token)"
    ns="${NAMESPACE:-kube-system}"
    echo "creating digitalocean (access-token) in $ns"
    apply_secret "$ns" digitalocean --from-literal=access-token="$DIGITALOCEAN_TOKEN"
    ;;

  hetzner)
    command -v hcloud >/dev/null 2>&1 || die "hcloud CLI not found"
    [[ -n "${HCLOUD_TOKEN:-}" ]] || die "HCLOUD_TOKEN is not set"
    ns="${NAMESPACE:-kube-system}"
    echo "creating hcloud in $ns"
    apply_secret "$ns" hcloud --from-literal=hcloud="$HCLOUD_TOKEN"
    ;;

  contabo)
    echo "contabo: no load balancer / cloud-controller-manager integration; the controllers run as NodePort." >&2
    echo "contabo: nothing to create (route the node ports with MikroTik/HAProxy or add MetalLB later)." >&2
    ;;

  *)
    die "unknown provider '$PROVIDER' (expected aws|oci|do|digitalocean|hetzner|contabo)"
    ;;
esac
