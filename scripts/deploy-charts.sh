#!/usr/bin/env bash
# =============================================================================
# deploy-charts.sh — Deploys the nginx Helm chart.
#
# Usage:  ./scripts/deploy-charts.sh <nlb-dns-name>
#
# =============================================================================
set -euo pipefail

NLB_DNS="${1:-}"
[ -z "$NLB_DNS" ] && { echo "Usage: $0 <nlb-dns-name>"; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/config.yaml"
KUBECONFIG_DIR="$REPO_ROOT/.kubeconfigs"
ADMIN_KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_DIR/admin.kubeconfig}"

BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "${BLUE}[deploy-charts]${NC} $*"; }
ok()  { echo -e "${GREEN}[deploy-charts] ✓${NC} $*"; }
die() { echo -e "${RED}[deploy-charts] ✗ $*${NC}" >&2; exit 1; }

cfg() { yq e "$1" "$CONFIG"; }

DEPLOY_USER=$(cfg '.users[0].name')
DEPLOY_NS=$(cfg '.users[0].namespace')
DEPLOY_KUBECONFIG="$KUBECONFIG_DIR/${DEPLOY_USER}.kubeconfig"
NGINX_VERSION=$(cfg '.nginx.version')
NGINX_REPLICAS=$(cfg '.nginx.replicas')
SITE_TITLE=$(cfg '.nginx.site.title')
SITE_BODY=$(cfg '.nginx.site.body')
NODEPORT_HTTP=$(cfg '.aws.security_groups.nodeport_http')
NODEPORT_HTTPS=$(cfg '.aws.security_groups.nodeport_https')
CERT_MGR_ISSUER="selfsigned-cluster-issuer"

# Validate config values before invoking Helm
[ -n "$NGINX_VERSION" ]  || die "nginx.version is empty in config.yaml"
[ -n "$DEPLOY_NS" ]      || die "users[0].namespace is empty in config.yaml"
[ -n "$NODEPORT_HTTP" ]  || die "aws.security_groups.nodeport_http is empty"
[ -n "$NODEPORT_HTTPS" ] || die "aws.security_groups.nodeport_https is empty"
[[ "$NGINX_REPLICAS" =~ ^[1-9][0-9]*$ ]] \
  || die "nginx.replicas must be a positive integer, got: '$NGINX_REPLICAS'"
[[ "$NODEPORT_HTTP" =~ ^[0-9]+$ ]] && [ "$NODEPORT_HTTP" -ge 30000 ] && [ "$NODEPORT_HTTP" -le 32767 ] \
  || die "nodeport_http must be in range 30000-32767, got: '$NODEPORT_HTTP'"
[[ "$NODEPORT_HTTPS" =~ ^[0-9]+$ ]] && [ "$NODEPORT_HTTPS" -ge 30000 ] && [ "$NODEPORT_HTTPS" -le 32767 ] \
  || die "nodeport_https must be in range 30000-32767, got: '$NODEPORT_HTTPS'"



  [ -f "$DEPLOY_KUBECONFIG" ] || {
    echo "Deploy user kubeconfig not found: $DEPLOY_KUBECONFIG"
    echo "Run scripts/rbac-csr.sh first."
    exit 1
  }

  log "Deploying nginx as user '${DEPLOY_USER}' in namespace '${DEPLOY_NS}' (direct helm)..."
  log "  NLB DNS:    $NLB_DNS"
  log "  NodePort H: $NODEPORT_HTTP  S: $NODEPORT_HTTPS"
  log "  Replicas:   $NGINX_REPLICAS"

  # Write a temp values override for fields that contain characters (em dashes,
  # commas) that Helm's --set parser would misinterpret.
  OVERRIDE_DIR=$(mktemp -d)
  OVERRIDE_VALUES="$OVERRIDE_DIR/values.yaml"
  trap 'rm -rf "$OVERRIDE_DIR"' EXIT
  cat > "$OVERRIDE_VALUES" <<YAMLEOF
staticSite:
  title: "${SITE_TITLE}"
  body: "${SITE_BODY}"
tls:
  commonName: "${NLB_DNS}"
YAMLEOF

  HELM_DRIVER=configmap helm upgrade --install nginx "$REPO_ROOT/helm/nginx" \
    --kubeconfig="$DEPLOY_KUBECONFIG" \
    --namespace "$DEPLOY_NS" \
    --set image.tag="$NGINX_VERSION" \
    --set replicaCount="$NGINX_REPLICAS" \
    --set service.nodePortHttp="$NODEPORT_HTTP" \
    --set service.nodePortHttps="$NODEPORT_HTTPS" \
    --set certManager.issuerName="$CERT_MGR_ISSUER" \
    --values "$OVERRIDE_VALUES" \
    --wait \
    --timeout 5m
  ok "Nginx Helm chart deployed."

  log "Rollout status:"
  kubectl --kubeconfig="$DEPLOY_KUBECONFIG" \
    rollout status deployment/nginx -n "$DEPLOY_NS" --timeout=120s

log "Pods in $DEPLOY_NS:"
kubectl --kubeconfig="$ADMIN_KUBECONFIG" get pods -n "$DEPLOY_NS" -o wide

log "Certificate:"
kubectl --kubeconfig="$ADMIN_KUBECONFIG" get certificate -n "$DEPLOY_NS"
