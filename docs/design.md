# Design Document — Kubernetes + Nginx Teleport Demo

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Key Design Decisions](#key-design-decisions)
   - [1. Single config.yaml as the source of truth](#1-single-configyaml-as-the-source-of-truth)
   - [2. kubeadm on AWS EC2](#2-kubeadm-on-aws-ec2-not-eks-not-minikube)
   - [3. Cloud-init for fully automated node bootstrap](#3-cloud-init-for-fully-automated-node-bootstrap)
   - [4. Network Load Balancer with TCP passthrough](#4-network-load-balancer-with-tcp-passthrough)
   - [5. Calico CNI](#5-calico-cni)
   - [6. RBAC via Certificate Signing Requests](#6-rbac-via-certificate-signing-requests)
   - [7. Least-privilege RBAC Role](#7-least-privilege-rbac-role)
   - [8. Helm for application delivery](#8-helm-for-application-delivery)
   - [9. nginxinc/nginx-unprivileged](#9-nginxincnginx-unprivileged)
   - [10. Self-signed TLS via cert-manager](#10-self-signed-tls-via-cert-manager)
4. [Security Summary](#security-summary)
5. [Known Limitations and Tradeoffs](#known-limitations-and-tradeoffs)
6. [Repository Structure](#repository-structure)

---

## Overview

This project provisions a three-node kubeadm Kubernetes cluster on AWS, deploys a static Nginx site with self-signed TLS, and demonstrates least-privilege access via Kubernetes RBAC and Certificate Signing Requests (CSR). The entire deployment is driven from a single configuration file and a single bootstrap command.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Operator Workstation (Ubuntu 24.04 LTS)                        │
│  Tools: terraform, helm, kubectl, aws-cli, yq, openssl          │
│  Entry point: ./scripts/bootstrap.sh                            │
└────────────────┬────────────────────────────────────────────────┘
                 │  terraform apply
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  AWS region                                               │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  VPC 10.0.0.0/16                                         │   │
│  │                                                           │   │
│  │  ┌────────────────┐   ┌──────────┐  ┌──────────┐        │   │
│  │  │ control-plane  │   │ worker-1 │  │ worker-2 │        │   │
│  │  │ t3.medium      │   │ t3.medium│  │ t3.medium│        │   │
│  │  │ kubeadm init   │   │ kubeadm  │  │ kubeadm  │        │   │
│  │  └────────────────┘   │ join     │  │ join     │        │   │
│  │       SSM Parameter   └────┬─────┘  └────┬─────┘        │   │
│  │       Store                │              │              │   │
│  │       (join-command,       ▼              ▼              │   │
│  │        kubeconfig)   NodePort 30080/30443 (workers only) │   │
│  │                            │              │              │   │
│  │  ┌─────────────────────────▼──────────────▼──────────┐  │   │
│  │  │  NLB (Network Load Balancer)                       │  │   │
│  │  │  :80  → TG → NodePort 30080 (HTTP → redirect)     │  │   │
│  │  │  :443 → TG → NodePort 30443 (HTTPS, TCP passthru) │  │   │
│  │  └────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Design Decisions

### 1. Single config.yaml as the source of truth

All tuneable parameters (AWS region, instance types, disk sizes, k8s version, nginx version, NodePort numbers, load balancer name, users, roles, Calico version) live in `config.yaml`. Terraform reads it via `yamldecode(file(...))` and shell scripts read it via `yq`. No values are duplicated across files.

### 2. kubeadm on AWS EC2 (not EKS, not Minikube)

The assignment explicitly requires kubeadm. This is the manual, production-grade Kubernetes installer that requires understanding of each component. EKS would abstract this; kubeadm does not.

**Tradeoff:** More operational burden (manual upgrades, etcd backup, cert rotation) vs. full visibility and control of every cluster component. This tradeoff is exactly what Teleport addresses — complexity of access management at the infrastructure layer.

### 3. Cloud-init for fully automated node bootstrap

All three nodes bootstrap via `user_data` (cloud-init) with zero SSH required. The control-plane writes its join token and admin kubeconfig to SSM Parameter Store (SecureString). Workers poll SSM until the join command is available. This eliminates the Terraform provisioner race condition and requires no open port 22.

**SSM over SSH:** IAM instance profiles grant nodes scoped access to `/k8s/<cluster-name>/*` SSM parameters only. No other AWS permissions are granted.

**Calico retry guard:** The Calico manifest apply loop on the control-plane tracks success with a `CALICO_OK` flag and calls `exit 1` after all retries are exhausted, so a CNI failure surfaces immediately rather than leaving the cluster silently un-networked.

**Worker join command:** The join command is executed via `bash -c "$JOIN_CMD"` (not `eval`) to avoid word-splitting surprises on the multi-flag kubeadm invocation.

### 4. Network Load Balancer with TCP passthrough

The NLB operates at Layer 4 (TCP). TLS terminates at the nginx pod — the self-signed certificate travels all the way to the browser. This avoids needing an ACM certificate and demonstrates the full TLS chain.

**Security group model:** Worker nodes allow NodePort traffic (30080, 30443) only from the VPC CIDR. Since NLB traffic originates within the VPC, this effectively restricts public internet access to "through the NLB only." Port 6443 (Kubernetes API) is open to `allowed_admin_cidrs` so `kubectl` works from the bastion/laptop outside the VPC.

**Tradeoff vs ALB:** An ALB would enable path-based routing, WAF integration, and native SG references for tighter port control. The NLB is simpler and appropriate for a TCP-level demo, especially with self-signed certs.

### 5. Calico CNI

Calico provides NetworkPolicy support (Flannel does not). This allows future enforcement of pod-to-pod traffic restrictions — another layer of least-privilege that aligns with Teleport's security model.

The Calico manifest version is configurable via `calico.version` in `config.yaml` and is threaded through `locals.tf` and the cloud-init template, so it is updated in one place alongside every other component version.

### 6. RBAC via Certificate Signing Requests

The deploy user's identity is a Kubernetes client certificate:
- **CN** (Common Name) → Kubernetes username (`deploy-user`)
- **O** (Organization) → Kubernetes group (`deploy-team`)

The workflow (`rbac-csr.sh`):
1. Generate RSA-4096 private key on the bastion
2. Generate a CSR (openssl)
3. Submit a `CertificateSigningRequest` object to the K8s API
4. Admin approves it (`kubectl certificate approve`)
5. K8s signs it using the cluster CA
6. Retrieve the signed cert and embed it in a user kubeconfig

The Kubernetes PKI here is doing exactly what Teleport does — issuing identity-bound certificates. The key differences: Teleport automates renewal, provides audit logs, supports MFA, and handles revocation. Kubernetes CSR-based users have no native revocation mechanism and certificates don't expire until `expirationSeconds` is reached.

### 7. Least-privilege RBAC Role

The `nginx-deployer` Role is namespace-scoped to `nginx-app`. It grants:
- CRUD on `deployments`, `replicasets`, `services`, `configmaps`
- Read on `pods`, `pods/log`, `secrets` (to verify cert issuance)
- CRUD on `cert-manager.io/certificates`
- CRUD on `poddisruptionbudgets`

It does **not** grant:
- Any cluster-scoped access
- Secrets write access (Helm uses `--storage-driver=configmap`)
- Access to any other namespace
- Node, PersistentVolume, or RBAC resource access

### 8. Helm for application delivery

Helm manages cert-manager (installed as admin) and the nginx application (installed as the deploy user). Using `--storage-driver=configmap` for the deploy user's Helm release avoids granting Secrets write access.

The nginx Helm chart is self-contained in `helm/nginx/` and fully overridable via values. Values containing special characters (em dashes, commas) are passed via a `--values` override file written to a `mktemp` path rather than via `--set`, avoiding Helm's argument parser misinterpreting them.

### 9. nginxinc/nginx-unprivileged

The nginx container runs as UID 101 (non-root) and listens on ports 8080/8443 (above 1024). Combined with `runAsNonRoot: true`, dropped capabilities, and emptyDir volumes for writable paths, the container has no elevated OS permissions.

### 10. Self-signed TLS via cert-manager

cert-manager's `selfSigned` ClusterIssuer generates a CA and issues certificates. In production, this issuer reference in `values.yaml` would be replaced with an ACME (Let's Encrypt) or enterprise CA issuer — no chart changes required, only a values override.

---

## Security Summary

| Layer | Control |
|---|---|
| AWS network | SGs restrict NodePorts to VPC CIDR; port 6443 to `allowed_admin_cidrs`; no open port 22 |
| Node identity | IAM instance profiles scoped to cluster SSM prefix only |
| Cluster access | CSR-issued client certificates, 24-hour expiry |
| User permissions | Namespace-scoped Role, no cluster-wide access |
| Container | Non-root (UID 101), capabilities dropped, no privilege escalation |
| TLS | cert-manager self-signed; modern ciphers (TLS 1.2/1.3 only) |
| Helm state | ConfigMap storage driver (no Secrets write for deploy user) |

---

## Known Limitations and Tradeoffs

### CSR-based user management (the core problem Teleport solves)

| Issue | Impact |
|---|---|
| No revocation | A compromised cert is valid until expiry |
| Manual workflow | Generating, submitting, and approving CSRs is error-prone at scale |
| No MFA | Certificate issuance has no second factor |
| No audit trail | K8s API audit logs exist but are not tied to a user identity management system |
| Cert rotation burden | Each user must manually rotate their cert before expiry |
| kubeconfig distribution | Securely delivering kubeconfigs to users is unsolved |

Teleport replaces all of the above with a unified identity plane: SSO integration, MFA, short-lived certs (automatically renewed), full session recording, and centralized policy.

### Infrastructure choices for this demo

| Choice | Tradeoff |
|---|---|
| Public subnets for all nodes | Simpler, lower cost vs. private subnets + NAT Gateway (production standard) |
| Single AZ control plane | No HA etcd; in production, 3 control-plane nodes across 3 AZs |
| No etcd backup | Not appropriate for production |
| Self-signed cert | Browser warning; production would use ACME or enterprise CA |
| NLB health check on TCP | Does not validate application health; HTTP health check on `/healthz` would be better (requires NLB → ALB migration) |

---

## Repository Structure

```
.
├── config.yaml                     ← Single source of truth for all parameters
├── scripts/
│   ├── bootstrap.sh                ← Full deployment entry point
│   ├── rbac-csr.sh                 ← CSR → kubeconfig automation
│   ├── deploy-charts.sh            ← Helm deploy as deploy user
│   └── verify.sh                   ← Smoke tests
├── terraform/
│   ├── main.tf                     ← Provider config
│   ├── locals.tf                   ← All values from config.yaml
│   ├── vpc.tf                      ← VPC, subnets, IGW, route tables
│   ├── security_groups.tf          ← NLB SG + node SG with NodePort + API rules
│   ├── iam.tf                      ← Node instance profile (SSM + SSM params)
│   ├── ec2.tf                      ← Control plane + 2 workers + NLB attachments
│   ├── lb.tf                       ← NLB + target groups + listeners
│   ├── ssm.tf                      ← SSM parameter placeholders
│   ├── outputs.tf                  ← NLB DNS + control_plane_public_ip
│   └── cloud-init/
│       ├── control-plane.yaml.tpl  ← Bootstraps k8s, writes SSM params
│       └── worker.yaml.tpl         ← Polls SSM, runs kubeadm join
├── helm/
│   └── nginx/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml     ← 2 replicas, non-root, security context
│           ├── service.yaml        ← NodePort 30080/30443
│           ├── configmap.yaml      ← Static HTML + nginx.conf with TLS
│           ├── certificate.yaml    ← cert-manager Certificate resource
│           └── poddisruptionbudget.yaml
├── k8s/
│   ├── rbac/
│   │   ├── namespace.yaml
│   │   ├── role.yaml               ← nginx-deployer: namespace-scoped, minimal
│   │   └── rolebinding.yaml        ← Binds deploy-user CN to Role
│   └── cert-manager/
│       └── cluster-issuer.yaml     ← selfSigned ClusterIssuer
└── docs/
    └── design.md                   ← This document
```
