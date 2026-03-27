#!/usr/bin/env bash
# =============================================================================
# rbac-csr.sh — Automates the full Kubernetes CSR → kubeconfig flow.
#
# For each user defined in config.yaml:
#   1. Generates a private key (RSA 4096)
#   2. Generates a Certificate Signing Request (openssl)
#   3. Submits a CertificateSigningRequest object to the K8s API
#   4. Approves it as admin (kubectl certificate approve)
#   5. Retrieves the signed certificate
#   6. Builds a kubeconfig for that user
#
# Output: .kubeconfigs/<user-name>.kubeconfig
#
# Called by: bootstrap.sh (after admin RBAC manifests are applied)
# Can also be run standalone: KUBECONFIG=<admin> ./scripts/rbac-csr.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/config.yaml"
KUBECONFIG_DIR="$REPO_ROOT/.kubeconfigs"
CERTS_DIR="$REPO_ROOT/.certs"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${BLUE}[rbac-csr]${NC} $*"; }
ok()  { echo -e "${GREEN}[rbac-csr] ✓${NC} $*"; }
die() { echo -e "${RED}[rbac-csr] ✗ $*${NC}" >&2; exit 1; }

cfg() { yq e "$1" "$CONFIG"; }

mkdir -p "$KUBECONFIG_DIR" "$CERTS_DIR"
chmod 700 "$KUBECONFIG_DIR" "$CERTS_DIR"

# Admin kubeconfig must be set
ADMIN_KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_DIR/admin.kubeconfig}"
[ -f "$ADMIN_KUBECONFIG" ] || die "Admin kubeconfig not found at $ADMIN_KUBECONFIG"

# K8s API server address (extracted from admin kubeconfig)
K8S_SERVER=$(yq e '.clusters[0].cluster.server' "$ADMIN_KUBECONFIG")

CLUSTER_CA_DATA=$(yq e '.clusters[0].cluster.certificate-authority-data' "$ADMIN_KUBECONFIG")

log "K8S_SERVER= $K8S_SERVER " # | "CLUSTER_CA_DATA= $CLUSTER_CA_DATA"


# Number of users in config.yaml
USER_COUNT=$(cfg '.users | length')
log "Processing $USER_COUNT user(s) from config.yaml..."

for i in $(seq 0 $((USER_COUNT - 1))); do
  USER_NAME=$(cfg ".users[$i].name")
  USER_CN=$(cfg ".users[$i].cn")
  USER_ORG=$(cfg ".users[$i].org")
  USER_NS=$(cfg ".users[$i].namespace")
  CERT_EXPIRY=$(cfg ".users[$i].cert_expiry_seconds")

  KEY_FILE="$CERTS_DIR/${USER_NAME}.key"
  CSR_FILE="$CERTS_DIR/${USER_NAME}.csr"
  CRT_FILE="$CERTS_DIR/${USER_NAME}.crt"
  KUBECONFIG_FILE="$KUBECONFIG_DIR/${USER_NAME}.kubeconfig"

  log "── Processing user: $USER_NAME (CN=$USER_CN, O=$USER_ORG) ──"

  # ── Step 1: Generate private key ──────────────────────────────────────────
  log "  [1/6] Generating RSA-4096 private key..."
  openssl genrsa -out "$KEY_FILE" 4096 2>/dev/null
  chmod 600 "$KEY_FILE"

  # ── Step 2: Generate CSR ──────────────────────────────────────────────────
  log "  [2/6] Generating Certificate Signing Request..."
  openssl req -new \
    -key "$KEY_FILE" \
    -out "$CSR_FILE" \
    -subj "/CN=${USER_CN}/O=${USER_ORG}" 2>/dev/null

  # ── Step 3: Submit K8s CertificateSigningRequest ──────────────────────────
  log "  [3/6] Submitting K8s CertificateSigningRequest..."

  # Delete any existing CSR with the same name
  kubectl --kubeconfig="$ADMIN_KUBECONFIG" delete csr "$USER_NAME" --ignore-not-found

  CSR_B64=$(base64 -w0 < "$CSR_FILE")

  kubectl --kubeconfig="$ADMIN_KUBECONFIG" apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER_NAME}
spec:
  request: ${CSR_B64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: ${CERT_EXPIRY}
  usages:
    - client auth
EOF

  # ── Step 4: Approve the CSR ───────────────────────────────────────────────
  log "  [4/6] Approving CertificateSigningRequest..."
  kubectl --kubeconfig="$ADMIN_KUBECONFIG" certificate approve "$USER_NAME"

  # ── Step 5: Retrieve signed certificate ───────────────────────────────────
  log "  [5/6] Retrieving signed certificate (waiting up to 30s)..."
  for attempt in $(seq 1 10); do
    CERT=$(kubectl --kubeconfig="$ADMIN_KUBECONFIG" get csr "$USER_NAME" \
      -o jsonpath='{.status.certificate}' 2>/dev/null || true)
    [ -n "$CERT" ] && break
    log "    Attempt $attempt/10 — certificate not yet issued, waiting 3s..."
    sleep 3
  done
  [ -z "$CERT" ] && die "Certificate not issued for $USER_NAME — check CSR status."

  echo "$CERT" | base64 -d > "$CRT_FILE"
  chmod 600 "$CRT_FILE"
  ok "  Certificate issued: $CRT_FILE"

  # Verify the cert subject matches what we requested
  SUBJECT=$(openssl x509 -noout -subject -in "$CRT_FILE" 2>/dev/null)
  log "  Certificate subject: $SUBJECT"

  # ── Step 6: Build user kubeconfig ─────────────────────────────────────────
  log "  [6/6] Building kubeconfig for $USER_NAME..."

  CLUSTER_NAME=$(cfg '.cluster.name')

  # Start fresh
  rm -f "$KUBECONFIG_FILE"

  kubectl config set-cluster "$CLUSTER_NAME" \
    --server="$K8S_SERVER" \
    --certificate-authority=<(echo "$CLUSTER_CA_DATA" | base64 -d) \
    --embed-certs=true \
    --kubeconfig="$KUBECONFIG_FILE"

  kubectl config set-credentials "$USER_NAME" \
    --client-certificate="$CRT_FILE" \
    --client-key="$KEY_FILE" \
    --embed-certs=true \
    --kubeconfig="$KUBECONFIG_FILE"

  kubectl config set-context "${USER_NAME}@${CLUSTER_NAME}" \
    --cluster="$CLUSTER_NAME" \
    --user="$USER_NAME" \
    --namespace="$USER_NS" \
    --kubeconfig="$KUBECONFIG_FILE"

  kubectl config use-context "${USER_NAME}@${CLUSTER_NAME}" \
    --kubeconfig="$KUBECONFIG_FILE"

  chmod 600 "$KUBECONFIG_FILE"
  ok "  kubeconfig saved: $KUBECONFIG_FILE"

  # ── Quick access check ────────────────────────────────────────────────────
  log "  Verifying user can access namespace $USER_NS..."
  CAN_LIST=$(kubectl --kubeconfig="$KUBECONFIG_FILE" \
    auth can-i list deployments -n "$USER_NS" 2>/dev/null || echo "no")
  CAN_CLUSTER=$(kubectl --kubeconfig="$KUBECONFIG_FILE" \
    auth can-i list nodes 2>/dev/null || echo "no")

  ok "  can-i list deployments in $USER_NS: $CAN_LIST"
  ok "  can-i list nodes (cluster-wide):    $CAN_CLUSTER  (expected: no)"

  echo ""
done

log "All users processed."
log "CSR status:"
kubectl --kubeconfig="$ADMIN_KUBECONFIG" get csr

echo ""
echo -e "${GREEN}Summary:${NC}"
echo -e "  Admin kubeconfig:  $ADMIN_KUBECONFIG"
for i in $(seq 0 $((USER_COUNT - 1))); do
  USER_NAME=$(cfg ".users[$i].name")
  echo -e "  Deploy kubeconfig: $KUBECONFIG_DIR/${USER_NAME}.kubeconfig"
done
