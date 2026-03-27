#!/usr/bin/env bash
# =============================================================================
# destroy.sh — Tears down all infrastructure and cleans up local credentials.
#
# Usage:  ./scripts/destroy.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DESTROY_LOG="$REPO_ROOT/scripts/logs/destroy.log"
exec > >(tee -a "$DESTROY_LOG") 2>&1
echo "[destroy] Logging to $DESTROY_LOG"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[destroy]${NC} $*"; }
ok()   { echo -e "${GREEN}[destroy] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[destroy] ⚠${NC} $*"; }
die()  { echo -e "${RED}[destroy] ✗ $*${NC}" >&2; exit 1; }

CONFIG="$REPO_ROOT/config.yaml"
CLUSTER_NAME=$(yq e '.cluster.name' "$CONFIG")

echo ""
warn "This will PERMANENTLY DESTROY all AWS infrastructure for cluster: ${CLUSTER_NAME}"
warn "All EC2 instances, VPC, NLB, IAM roles, and SSM parameters will be deleted."
warn "This action cannot be undone."
echo ""
read -rp "  Type the cluster name to confirm: " CONFIRM
[ "$CONFIRM" = "$CLUSTER_NAME" ] \
  || die "Confirmation did not match '${CLUSTER_NAME}'. Aborting."
echo ""

log "Removing local kubeconfigs and certs..."
rm -rf "$REPO_ROOT/.kubeconfigs" "$REPO_ROOT/.certs"
ok "Local credentials removed."

log "Running terraform destroy..."
cd "$REPO_ROOT/terraform"
terraform destroy -auto-approve -input=false
ok "All AWS resources destroyed."
