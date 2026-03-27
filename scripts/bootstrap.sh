#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Single entry point for the full deployment.
#
# Usage:  ./scripts/bootstrap.sh
#
# What it does (in order):
#   1. Validates local tooling dependencies
#   2. Runs terraform (provision VPC, EC2, NLB, IAM, SSM)
#   3. Polls SSM until the control-plane bootstrap is complete
#   4. Retrieves admin kubeconfig from SSM
#   5. Installs cert-manager via Helm
#   6. Applies ClusterIssuer + namespace + RBAC manifests (as admin)
#   7. Runs rbac-csr.sh to create the deploy user and their kubeconfig
#   8. Deploys the nginx Helm chart as the deploy user
#   9. Runs verify.sh to confirm everything is healthy
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Tee all output to a local log file for post-mortem debugging
BOOTSTRAP_LOG="$REPO_ROOT/scripts/logs/bootstrap.log"
exec > >(tee -a "$BOOTSTRAP_LOG") 2>&1
echo "[bootstrap] Logging to $BOOTSTRAP_LOG"
SCRIPTS_DIR="$REPO_ROOT/scripts"
CONFIG="$REPO_ROOT/config.yaml"
KUBECONFIG_DIR="$REPO_ROOT/.kubeconfigs"
ADMIN_KUBECONFIG="$KUBECONFIG_DIR/admin.kubeconfig"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[bootstrap]${NC} $*"; }
ok()   { echo -e "${GREEN}[bootstrap] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[bootstrap] ⚠${NC} $*"; }
die()  { echo -e "${RED}[bootstrap] ✗ $*${NC}" >&2; exit 1; }

# ── Read config values using yq ───────────────────────────────────────────────
cfg() { yq e "$1" "$CONFIG"; }

# ── 0. Preflight checks ───────────────────────────────────────────────────────
log "Checking required tools..."
for tool in terraform helm kubectl aws yq envsubst; do
  command -v "$tool" &>/dev/null || die "Required tool not found: $tool"
done
YQ_MAJOR=$(yq --version 2>&1 | grep -oP 'v?\K\d+(?=\.\d)' | head -1)
[ "${YQ_MAJOR:-0}" -ge 4 ] \
  || die "yq v4+ required (yq e syntax); found: $(yq --version 2>&1 | head -1)"
ok "All tools present."

# ── 0b. Validate required config.yaml keys ───────────────────────────────────
log "Validating config.yaml..."
for key in \
  '.cluster.name' '.cluster.kubernetes_version' \
  '.cluster.pod_cidr' '.cluster.service_cidr' \
  '.aws.region' '.aws.vpc.cidr' \
  '.aws.ec2.workers.count' \
  '.calico.version' '.cert_manager.version'; do
  val=$(cfg "$key")
  [ -n "$val" ] && [ "$val" != "null" ] \
    || die "config.yaml missing required key: $key"
done
ok "config.yaml validated."

# Validate CIDRs don't overlap (compare first two octets as a basic check)
VPC_PREFIX=$(cfg '.aws.vpc.cidr'         | cut -d. -f1-2)
POD_PREFIX=$(cfg '.cluster.pod_cidr'     | cut -d. -f1-2)
SVC_PREFIX=$(cfg '.cluster.service_cidr' | cut -d. -f1-2)
[ "$VPC_PREFIX" != "$POD_PREFIX" ] \
  || die "pod_cidr overlaps vpc_cidr — fix config.yaml"
[ "$VPC_PREFIX" != "$SVC_PREFIX" ] \
  || die "service_cidr overlaps vpc_cidr — fix config.yaml"
ok "CIDR ranges validated."

AWS_REGION=$(cfg '.aws.region')
CLUSTER_NAME=$(cfg '.cluster.name')
CERT_MANAGER_VERSION=$(cfg '.cert_manager.version')

SSM_KUBECONFIG_PARAM="/k8s/${CLUSTER_NAME}/kubeconfig"
SSM_JOIN_PARAM="/k8s/${CLUSTER_NAME}/join-command"

mkdir -p "$KUBECONFIG_DIR"
chmod 700 "$KUBECONFIG_DIR"

# ── 1. Terraform ──────────────────────────────────────────────────────────────
log "Running terraform init + apply..."
cd "$REPO_ROOT/terraform"
terraform init -input=false
terraform apply -auto-approve -input=false
NLB_DNS=$(terraform output -raw nlb_dns_name)
CP_PUBLIC_IP=$(terraform output -raw control_plane_public_ip)
ok "Terraform complete. NLB DNS: $NLB_DNS  CP public IP: $CP_PUBLIC_IP"
cd "$REPO_ROOT"

# Verify SSM parameters are readable before entering the 20-min polling loop.
log "Verifying SSM parameter accessibility..."
aws ssm get-parameter --name "$SSM_KUBECONFIG_PARAM" \
  --region "$AWS_REGION" &>/dev/null \
  || die "Cannot read SSM parameter $SSM_KUBECONFIG_PARAM — check IAM permissions and terraform output"
ok "SSM parameters accessible."

# ── 2. Wait for control-plane bootstrap to complete ───────────────────────────
log "Waiting for control-plane to write kubeconfig to SSM (up to 20 min)..."
MAX=120
for i in $(seq 1 $MAX); do
  VALUE=$(aws ssm get-parameter \
    --name "$SSM_KUBECONFIG_PARAM" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || true)

  if [ -n "$VALUE" ] && [ "$VALUE" != "placeholder" ]; then
    ok "kubeconfig available in SSM."
    break
  fi
  log "  Attempt $i/$MAX — control-plane still bootstrapping (10s)..."
  sleep 10
done

# NOTE: do not collapse back to a one-liner with || and &&.
# In bash && binds tighter than ||, so  A || B && C  is  A || (B && C).
# That means if VALUE="placeholder" the die would never fire.
if [ "$VALUE" = "placeholder" ] || [ -z "$VALUE" ]; then
  die "Timed out waiting for kubeconfig in SSM. Check /var/log/k8s-bootstrap.log on the control-plane."
fi

# ── 3. Retrieve admin kubeconfig ──────────────────────────────────────────────
log "Retrieving admin kubeconfig from SSM..."
aws ssm get-parameter \
  --name "$SSM_KUBECONFIG_PARAM" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region "$AWS_REGION" > "$ADMIN_KUBECONFIG"
chmod 600 "$ADMIN_KUBECONFIG"

# Patch the server address: kubeconfig contains the private IP; replace with the
# public IP captured from terraform output (no kubectl needed — avoids chicken-and-egg).
yq e ".clusters[0].cluster.server = \"https://${CP_PUBLIC_IP}:6443\"" \
  -i "$ADMIN_KUBECONFIG"

export KUBECONFIG="$ADMIN_KUBECONFIG"
ok "Admin kubeconfig saved to $ADMIN_KUBECONFIG"

# ── 4. Wait for all nodes Ready ───────────────────────────────────────────────
WORKER_COUNT=$(cfg '.aws.ec2.workers.count')
log "Waiting for all $((WORKER_COUNT + 1)) nodes to be Ready..."
kubectl wait node --all --for=condition=Ready --timeout=300s
ok "All nodes Ready."

# ── 5. Install cert-manager via Helm ─────────────────────────────────────────
log "Installing cert-manager $CERT_MANAGER_VERSION..."
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "$CERT_MANAGER_VERSION" \
  --set crds.enabled=true \
  --set podDisruptionBudget.enabled=true \
  --wait \
  --timeout 5m
ok "cert-manager installed."


# ── 6. Apply admin-scoped resources ──────────────────────────────────────────
log "Applying namespace, ClusterIssuer, and RBAC manifests..."
kubectl apply -f "$REPO_ROOT/k8s/rbac/namespace.yaml"
kubectl apply -f "$REPO_ROOT/k8s/cert-manager/cluster-issuer.yaml"
kubectl apply -f "$REPO_ROOT/k8s/rbac/role.yaml"
kubectl apply -f "$REPO_ROOT/k8s/rbac/rolebinding.yaml"
kubectl apply -f "$REPO_ROOT/k8s/rbac/resource-quota.yaml"
VPC_CIDR=$(cfg '.aws.vpc.cidr')
export VPC_CIDR
envsubst < "$REPO_ROOT/k8s/network-policies/nginx-app.yaml" | kubectl apply -f -
ok "Admin manifests applied."

# ── 7. Create deploy user via CSR ────────────────────────────────────────────
log "Running RBAC/CSR flow..."
"$SCRIPTS_DIR/rbac-csr.sh"
ok "Deploy user created."

# ── 8. Deploy nginx as the deploy user ───────────────────────────────────────
log "Deploying nginx Helm chart as deploy-user..."
"$SCRIPTS_DIR/deploy-charts.sh" "$NLB_DNS"
ok "Nginx deployed."

# ── 9. Verify ────────────────────────────────────────────────────────────────
log "Running smoke tests..."
"$SCRIPTS_DIR/verify.sh" "$NLB_DNS"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Deployment complete!${NC}"
echo -e "${GREEN}  HTTP:  http://${NLB_DNS}${NC}"
echo -e "${GREEN}  HTTPS: https://${NLB_DNS}  (self-signed cert — accept browser warning)${NC}"
echo -e "${GREEN}  Admin kubeconfig:  $ADMIN_KUBECONFIG${NC}"
echo -e "${GREEN}  Deploy kubeconfig: $KUBECONFIG_DIR/deploy-user.kubeconfig${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"

# Clean up exported KUBECONFIG so it does not persist if this script
# was sourced rather than executed in a subshell.
unset KUBECONFIG
