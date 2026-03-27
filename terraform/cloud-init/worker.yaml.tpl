#cloud-config
# Worker node bootstrap — runs once on first boot via cloud-init.
# Polls SSM until the control-plane writes the join command, then joins.
# Logs to /var/log/k8s-bootstrap.log for easy debugging.

write_files:
  # ── Kernel module load list ───────────────────────────────────────────────
  - path: /etc/modules-load.d/k8s.conf
    owner: root:root
    permissions: "0644"
    content: |
      overlay
      br_netfilter

  # ── Sysctl settings required by kubeadm ──────────────────────────────────
  - path: /etc/sysctl.d/99-k8s.conf
    owner: root:root
    permissions: "0644"
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1

  # ── containerd config (SystemdCgroup required for k8s) ───────────────────
  - path: /etc/containerd/config.toml
    owner: root:root
    permissions: "0644"
    content: |
      version = 2
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
        runtime_type = "io.containerd.runc.v2"
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
          SystemdCgroup = true

  # ── Bootstrap script ─────────────────────────────────────────────────────
  - path: /usr/local/bin/k8s-bootstrap-worker.sh
    owner: root:root
    permissions: "0700"
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

      AWS_REGION="${aws_region}"
      SSM_JOIN="${ssm_join_param}"
      K8S_MINOR="${k8s_version}"

      # On any unhandled error, log clearly and exit. bootstrap.sh detects
      # the missing node via kubectl wait --for=condition=Ready.
      trap 'log "Worker bootstrap FAILED — check /var/log/k8s-bootstrap.log on this node."' ERR

      # ── 1. Disable swap ────────────────────────────────────────────────
      log "Disabling swap..."
      swapoff -a
      sed -i '/\sswap\s/d' /etc/fstab

      # ── 2. Load kernel modules ─────────────────────────────────────────
      log "Loading kernel modules..."
      modprobe overlay
      modprobe br_netfilter
      sysctl --system

      # ── 3. Install containerd ──────────────────────────────────────────
      log "Installing containerd..."
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -q
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confold" \
        containerd.io
      systemctl enable --now containerd
      systemctl restart containerd

      # ── 4. Install kubeadm / kubelet ──────────────────────────────────
      log "Installing kubeadm v$${K8S_MINOR}..."
      curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$${K8S_MINOR}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
        https://pkgs.k8s.io/core:/stable:/v$${K8S_MINOR}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list
      apt-get update -q
      apt-get install -y kubelet kubeadm kubectl
      apt-mark hold kubelet kubeadm kubectl
      systemctl enable kubelet

      # ── 4b. Install AWS CLI v2 ─────────────────────────────────────────
      log "Installing AWS CLI v2..."
      apt-get install -y unzip
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
      unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2
      /tmp/awscliv2/aws/install
      rm -rf /tmp/awscliv2.zip /tmp/awscliv2

      # ── 5. Poll SSM for join command ───────────────────────────────────
      log "Waiting for control-plane to write join command to SSM..."
      MAX_WAIT=120   # 20 minutes max (120 × 10s)
      for i in $(seq 1 $${MAX_WAIT}); do
        JOIN_CMD=$(aws ssm get-parameter \
          --name "$${SSM_JOIN}" \
          --with-decryption \
          --query 'Parameter.Value' \
          --output text \
          --region "$${AWS_REGION}" 2>/dev/null || true)

        # The placeholder written by Terraform is "placeholder" — skip it
        if [ -n "$${JOIN_CMD}" ] && [ "$${JOIN_CMD}" != "placeholder" ]; then
          if [ "$${JOIN_CMD}" = "error" ]; then
            log "ERROR: control-plane reported a bootstrap failure."
            log "Check /var/log/k8s-bootstrap.log on the control-plane node."
            exit 1
          fi
          log "Join command received."
          break
        fi
        log "  Attempt $${i}/$${MAX_WAIT} — control-plane not ready yet, waiting 10s..."
        sleep 10
      done

      if [ -z "$${JOIN_CMD}" ] || [ "$${JOIN_CMD}" = "placeholder" ]; then
        log "ERROR: timed out waiting for join command."
        exit 1
      fi

      # ── 6. Join the cluster ────────────────────────────────────────────
      # Use bash -c rather than eval to avoid word-splitting surprises with
      # the multi-flag kubeadm join command stored in the SSM parameter.
      log "Running kubeadm join..."
      bash -c "$${JOIN_CMD}"

      log "Worker bootstrap COMPLETE."

runcmd:
  - /usr/local/bin/k8s-bootstrap-worker.sh > /var/log/k8s-bootstrap.log 2>&1
