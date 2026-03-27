# Kubernetes + Nginx Teleport Demo

A fully automated deployment that provisions a kubeadm Kubernetes cluster on AWS, deploys a static Nginx site with self-signed TLS, and demonstrates least-privilege access via Kubernetes RBAC. The entire deployment runs from a single command.

---

## Table of Contents

1. [What This Does](#1-what-this-does)
2. [Pre-requisite Tools](#2-pre-requisite-tools)
3. [Key Configurations in config.yaml](#3-key-configurations-in-configyaml)
4. [Deployment Process Overview](#4-deployment-process-overview)
5. [How to Run](#5-how-to-run)

---

## 1. What This Does

This project automates the end-to-end provisioning and configuration of a three-node Kubernetes cluster on AWS, with a demo Nginx application exposed over HTTPS.

### Platform Stack

| Layer | Technology | Notes |
|---|---|---|
| **OS** | Ubuntu 24.04 LTS | All EC2 nodes and assumed bastion OS |
| **Infrastructure** | Terraform (>= 1.7) | Provisions all AWS resources |
| **Node bootstrap** | cloud-init (user_data) | Zero-SSH, fully automated node setup |
| **Cloud** | AWS | us-east-1 (configurable) |
| **Compute** | Ubuntu EC2 (t3.medium) | 1 control plane + 2 workers |
| **Load balancer** | AWS NLB | TCP passthrough; TLS terminates at the pod |
| **Kubernetes** | kubeadm 1.33 | Manual, production-grade cluster setup |
| **CNI** | Calico 3.30 | Required for NetworkPolicy support |
| **TLS** | cert-manager v1.17 | Self-signed ClusterIssuer; browser will warn |
| **Ingress** | Nginx (nginx-unprivileged) | Runs non-root (UID 101), stable-alpine tag |
| **Users** | 1 admin + 1 deploy user | CSR-issued client certificates |

### Access Model

- **Admin user** — full cluster access via kubeconfig retrieved from AWS SSM Parameter Store after bootstrap
- **deploy-user** — namespace-scoped RBAC role (`nginx-deployer`) in the `nginx-app` namespace, issued a 24-hour client certificate via Kubernetes CSR workflow. Can deploy and manage the nginx application; cannot access any other namespace or cluster-wide resources.

> For full architectural detail, design decisions, security model, and known trade-offs see [docs/design.md](docs/design.md) (to be included, later).

---

## 2. Pre-requisite Tools

All tools below must be present on the bastion (Ubuntu 24.04 LTS) before running `bootstrap.sh`.

| Tool | Minimum Version | Notes |
|---|---|---|
| `terraform` | >= 1.7.0 | AWS provider ~> 5.40 |
| `helm` | >= 3.14 | Used for cert-manager and nginx chart |
| `kubectl` | >= 1.33 | Should match or be within ±1 of cluster version |
| `aws` CLI | v2 | See IAM permissions below |
| `yq` | >= 4.x | Must support `yq e` syntax; v3 will fail |
| `jq` | any | Used in supporting scripts |
| `openssl` | any | RSA-4096 key + CSR generation for deploy user |
| `envsubst` | any | Part of `gettext` package on Ubuntu |
| `curl` | any | Used in smoke tests |

### AWS IAM Permissions

The AWS credentials used on the bastion were tested with the following managed policies attached:

- `AmazonEC2FullAccess`
- `AmazonSSMFullAccess`
- `ElasticLoadBalancingFullAccess`
- `IAMFullAccess`
- `IAMUserChangePassword`

### Tools Versions used for this release

| Tool | Version |
|---|---|
| `terraform` | 1.14.7 |
| `helm` | v3.20.1 |
| `kubectl` | v1.33.10 |
| `aws` CLI | 2.34.16 |
| `yq` | v4.52.4 |
| `jq` | 1.7 |
| `openssl` | 3.0.13 |
| `envsubst` | 0.21 (GNU gettext-runtime) |
| `curl` | 8.5.0 |

---

## 3. Key Configurations in config.yaml

`config.yaml` is the **single source of truth** for all deployment parameters. Terraform reads it via `yamldecode`, and all shell scripts read it via `yq`. Do not edit Terraform or Helm files directly.

### Important settings

| Key | Default | Description |
|---|---|---|
| `cluster.name` | `teleport-demo` | Used as a prefix for SSM parameters and AWS resource names |
| `cluster.kubernetes_version` | `1.33` | APT repo major.minor; patch auto-selected by kubeadm |
| `aws.region` | `us-east-1` | Target AWS region |
| `aws.ec2.workers.count` | `2` | Number of worker nodes |
| `aws.ec2.control_plane.instance_type` | `t3.medium` | Minimum: 2 vCPU / 4 GiB required by kubeadm |
| `aws.load_balancer.name` | `teleport-demo-nlb` | NLB resource name in AWS |
| `calico.version` | `3.30.0` | CNI manifest version |
| `cert_manager.version` | `v1.17.0` | Helm chart version |
| `nginx.version` | `stable-alpine` | Docker Hub tag for `nginxinc/nginx-unprivileged` |
| `nginx.replicas` | `2` | Number of nginx pod replicas |

### Security warning

```yaml
aws:
  security_groups:
    # WARNING: "0.0.0.0/0" exposes port 6443 (kubectl API) to the entire internet.
    # ALWAYS restrict to your office/bastion CIDR before deploying:
    #   allowed_admin_cidrs: ["203.0.113.10/32"]
    allowed_admin_cidrs:
      - "0.0.0.0/0"   # <-- CHANGE THIS
```

> **Action required:** Set `allowed_admin_cidrs` to your specific IP or CIDR range before running `bootstrap.sh`.

---

## 4. Deployment Process Overview

```
Bastion
  │
  ├─ terraform apply
  │     ├─ VPC, subnets, IGW, route tables
  │     ├─ Security groups
  │     ├─ IAM instance profiles (scoped SSM access)
  │     ├─ EC2 instances with cloud-init user_data
  │     │     ├─ control-plane: kubeadm init → Calico CNI → writes kubeconfig + join-command to SSM
  │     │     └─ workers: poll SSM for join-command → kubeadm join
  │     ├─ NLB + target groups (TCP :80 → NodePort 30080, TCP :443 → NodePort 30443)
  │     └─ SSM Parameter Store (placeholder params for kubeconfig + join-command)
  │
  ├─ Poll SSM until control-plane kubeconfig is available (up to 20 min)
  │
  ├─ Retrieve admin kubeconfig from SSM → patch server address → save to .kubeconfigs/
  │
  ├─ Wait for all nodes Ready (kubectl wait)
  │
  ├─ helm install cert-manager  (as admin, namespace: cert-manager)
  │
  ├─ kubectl apply
  │     ├─ namespace.yaml         (nginx-app)
  │     ├─ cluster-issuer.yaml    (selfSigned ClusterIssuer)
  │     ├─ role.yaml              (nginx-deployer, namespace-scoped)
  │     ├─ rolebinding.yaml       (deploy-user CN → nginx-deployer)
  │     ├─ resource-quota.yaml
  │     └─ network-policies/nginx-app.yaml
  │
  ├─ rbac-csr.sh
  │     ├─ Generate RSA-4096 key + CSR (openssl)
  │     ├─ Submit CertificateSigningRequest to K8s API
  │     ├─ Admin approves → K8s signs with cluster CA
  │     └─ Retrieve signed cert → embed in deploy-user.kubeconfig (24h expiry)
  │
  ├─ deploy-charts.sh  (helm upgrade --install nginx, as deploy-user)
  │
  └─ verify.sh  (smoke tests — see below)
```

---

## 5. How to Run

### 1. Configure AWS credentials

```bash
export AWS_PROFILE=your-profile
# or
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
```

### 2. Edit config.yaml

At minimum, update `aws.security_groups.allowed_admin_cidrs` to your IP:

```yaml
allowed_admin_cidrs:
  - "203.0.113.10/32"   # replace with your actual IP
```

Optionally adjust region, instance types, worker count, and component versions.

### 3. Run bootstrap

```bash
./scripts/bootstrap.sh
```

All output is **simultaneously logged** to `scripts/logs/bootstrap.log` for post-mortem debugging.

The script validates tools and config, then runs the full deployment pipeline. When complete, it prints:

```
════════════════════════════════════════════════════════
  Deployment complete!
  HTTP:  http://<nlb-dns>
  HTTPS: https://<nlb-dns>  (self-signed cert — accept browser warning)
  Admin kubeconfig:  .kubeconfigs/admin.kubeconfig
  Deploy kubeconfig: .kubeconfigs/deploy-user.kubeconfig
════════════════════════════════════════════════════════
```

### Verification stage

`verify.sh` runs automatically at the end of `bootstrap.sh` and performs the following smoke tests:

- All cluster nodes are `Ready`
- cert-manager pods are running and `ClusterIssuer` exists
- TLS Secret has been issued in the `nginx-app` namespace
- Nginx deployment has all replicas available
- HTTP endpoint returns 301 redirect to HTTPS
- HTTPS endpoint returns 200 with correct content (self-signed cert, `-k`)
- `deploy-user` can manage resources in `nginx-app` namespace
- `deploy-user` **cannot** list nodes, access `kube-system`, or create ClusterRoles

Results are printed as a pass/fail summary. Any failure exits with a non-zero status.

### Teardown

```bash
./scripts/destroy.sh
```

> For more details on architecture, design decisions, and known limitations see [docs/design.md](docs/design.md) (to be included later).
