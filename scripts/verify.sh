#!/usr/bin/env bash
# =============================================================================
# verify.sh — Smoke tests to confirm the deployment is healthy.
#
# Usage:  ./scripts/verify.sh <nlb-dns-name>
#
# Checks:
#   1. All nodes Ready
#   2. cert-manager pods Running
#   3. TLS Secret issued by cert-manager
#   4. nginx pods Running (all replicas)
#   5. HTTP endpoint reachable and redirects to HTTPS
#   6. HTTPS endpoint reachable and returns HTTP 200
#   7. Deploy user RBAC — can deploy, cannot access cluster-wide resources
# =============================================================================
set -euo pipefail

NLB_DNS="${1:-}"
[ -z "$NLB_DNS" ] && { echo "Usage: $0 <nlb-dns-name>"; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/config.yaml"
KUBECONFIG_DIR="$REPO_ROOT/.kubeconfigs"
ADMIN_KUBECONFIG="$KUBECONFIG_DIR/admin.kubeconfig"

cfg() { yq e "$1" "$CONFIG"; }

DEPLOY_USER=$(cfg '.users[0].name')
DEPLOY_NS=$(cfg '.users[0].namespace')
DEPLOY_KUBECONFIG="$KUBECONFIG_DIR/${DEPLOY_USER}.kubeconfig"

PASS=0; FAIL=0
check() {
  local desc="$1"; shift
  if "$@" &>/dev/null; then
    echo -e "  \033[0;32m✓\033[0m $desc"
    ((PASS++)) || true
  else
    echo -e "  \033[0;31m✗\033[0m $desc"
    ((FAIL++)) || true
  fi
}

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Smoke Tests — Teleport Demo Deployment"
echo "══════════════════════════════════════════════════════"
echo ""

echo "── Cluster health ──────────────────────────────────"
check "All nodes Ready" \
  kubectl --kubeconfig="$ADMIN_KUBECONFIG" wait node \
    --all --for=condition=Ready --timeout=30s

check "control-plane node exists" \
  kubectl --kubeconfig="$ADMIN_KUBECONFIG" get nodes \
    -l node-role.kubernetes.io/control-plane

WORKER_COUNT=$(cfg '.aws.ec2.workers.count')
check "$WORKER_COUNT worker nodes exist" bash -c \
  "[ \$(kubectl --kubeconfig='$ADMIN_KUBECONFIG' get nodes \
    --no-headers | grep -vc control-plane) -eq $WORKER_COUNT ]"

echo ""
echo "── cert-manager ────────────────────────────────────"
check "cert-manager pods Running" \
  kubectl --kubeconfig="$ADMIN_KUBECONFIG" wait pod \
    -l app.kubernetes.io/name=cert-manager \
    -n cert-manager \
    --for=condition=Ready \
    --timeout=60s

check "ClusterIssuer selfsigned-cluster-issuer exists" \
  kubectl --kubeconfig="$ADMIN_KUBECONFIG" get clusterissuer selfsigned-cluster-issuer

check "TLS Secret issued in $DEPLOY_NS" \
  kubectl --kubeconfig="$ADMIN_KUBECONFIG" get secret nginx-tls -n "$DEPLOY_NS"


echo ""
echo "── Nginx deployment ─────────────────────────────────"
REPLICAS=$(cfg '.nginx.replicas')
check "Deployment has $REPLICAS ready replicas" \
  kubectl --kubeconfig="$ADMIN_KUBECONFIG" wait deployment/nginx \
    -n "$DEPLOY_NS" \
    --for=condition=Available \
    --timeout=60s

check "All nginx pods Running" \
  kubectl --kubeconfig="$ADMIN_KUBECONFIG" wait pod \
    -l app.kubernetes.io/name=nginx \
    -n "$DEPLOY_NS" \
    --for=condition=Ready \
    --timeout=60s

echo ""
echo "── Network (NLB: $NLB_DNS) ──────────────────────────"
# NLB health checks run every 10 s and require 3 consecutive passes before a
# target is marked healthy.  Wait up to 90 s for the first successful HTTP
# response before running the connectivity checks.
echo "  Waiting for NLB to route traffic (up to 90 s)..."
NLB_READY=0
for i in $(seq 1 18); do
  HTTP_CODE=$(curl -sf --max-time 5 -o /dev/null -w '%{http_code}' \
    "http://${NLB_DNS}" 2>/dev/null || true)
  if [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "200" ]; then
    NLB_READY=1
    break
  fi
  echo "  attempt $i/18 — NLB not ready yet (http_code=${HTTP_CODE:-none}), waiting 5 s..."
  sleep 5
done
[ $NLB_READY -eq 1 ] || echo "  ⚠ NLB did not become ready in time — network checks may fail"

check "HTTP → HTTPS redirect (301)" bash -c \
  "curl -sf --max-time 30 -o /dev/null -w '%{http_code}' \
    http://${NLB_DNS} | grep -q '301'"

check "HTTPS returns 200 (self-signed cert, -k)" bash -c \
  "curl -skf --max-time 30 -o /dev/null -w '%{http_code}' \
    https://${NLB_DNS} | grep -q '200'"

check "HTTPS response contains 'Teleport Demo'" bash -c \
  "curl -skf --max-time 10 https://${NLB_DNS} | grep -q 'Teleport Demo'"

echo ""
echo "── RBAC validation (deploy user) ───────────────────"
check "deploy-user: can list deployments in $DEPLOY_NS" \
  kubectl --kubeconfig="$DEPLOY_KUBECONFIG" auth can-i list deployments -n "$DEPLOY_NS"

check "deploy-user: can list pods in $DEPLOY_NS" \
  kubectl --kubeconfig="$DEPLOY_KUBECONFIG" auth can-i list pods -n "$DEPLOY_NS"

check "deploy-user: CANNOT list nodes (cluster-wide)" bash -c \
  "! kubectl --kubeconfig='$DEPLOY_KUBECONFIG' auth can-i list nodes"

check "deploy-user: CANNOT access kube-system namespace" bash -c \
  "! kubectl --kubeconfig='$DEPLOY_KUBECONFIG' get pods -n kube-system 2>/dev/null"

check "deploy-user: CANNOT create ClusterRole" bash -c \
  "! kubectl --kubeconfig='$DEPLOY_KUBECONFIG' auth can-i create clusterroles"

echo ""
echo "══════════════════════════════════════════════════════"
echo -e "  Results: \033[0;32m$PASS passed\033[0m, \033[0;31m$FAIL failed\033[0m"
echo "══════════════════════════════════════════════════════"
echo ""

[ $FAIL -eq 0 ] || exit 1
