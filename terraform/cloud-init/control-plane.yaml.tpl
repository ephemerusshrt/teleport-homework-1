#cloud-config
# Control-plane bootstrap — runs once on first boot via cloud-init.
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

  # ── kubeadm init configuration ───────────────────────────────────────────
  - path: /etc/kubeadm/init-config.yaml
    owner: root:root
    permissions: "0600"
    content: |
      apiVersion: kubeadm.k8s.io/v1beta3
      kind: InitConfiguration
      localAPIEndpoint:
        # PRIVATE_IP is substituted at runtime by the bootstrap script
        advertiseAddress: PRIVATE_IP
        bindPort: 6443
      nodeRegistration:
        criSocket: unix:///run/containerd/containerd.sock
      ---
      apiVersion: kubeadm.k8s.io/v1beta3
      kind: ClusterConfiguration
      kubernetesVersion: "${k8s_version}"
      clusterName: "${cluster_name}"
      apiServer:
        certSANs:
          - PUBLIC_IP
        extraArgs:
          encryption-provider-config: /etc/kubernetes/encryption-config.yaml
        extraVolumes:
          - name: encryption-config
            hostPath: /etc/kubernetes/encryption-config.yaml
            mountPath: /etc/kubernetes/encryption-config.yaml
            readOnly: true
      networking:
        podSubnet: "${pod_cidr}"
        serviceSubnet: "${service_cidr}"
        dnsDomain: "${dns_domain}"
      ---
      apiVersion: kubelet.config.k8s.io/v1beta1
      kind: KubeletConfiguration
      cgroupDriver: systemd

  # ── etcd encryption config — generated key injected at bootstrap time ───
  - path: /etc/kubernetes/encryption-config.yaml
    owner: root:root
    permissions: "0600"
    content: |
      apiVersion: apiserver.config.k8s.io/v1
      kind: EncryptionConfiguration
      resources:
        - resources:
            - secrets
          providers:
            - aescbc:
                keys:
                  - name: key1
                    secret: ENCRYPTION_KEY_PLACEHOLDER
            - identity: {}

  # ── Bootstrap script ─────────────────────────────────────────────────────
  - path: /usr/local/bin/k8s-bootstrap-control-plane.sh
    owner: root:root
    permissions: "0700"
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

      AWS_REGION="${aws_region}"
      SSM_JOIN="${ssm_join_param}"
      SSM_KUBE="${ssm_kubeconfig_param}"
      SSM_ENC_KEY="${ssm_encryption_key_param}"
      K8S_MINOR="${k8s_version}"

      # On any unhandled error, write a sentinel so workers fail fast instead
      # of polling for 20 minutes with no signal.
      trap 'aws ssm put-parameter --name "$${SSM_JOIN}" --value "error" \
        --type SecureString --overwrite --region "$${AWS_REGION}" 2>/dev/null || true; \
        log "Control-plane bootstrap FAILED — error sentinel written to SSM."; \
        exit 1' ERR

      # ── 1. Disable swap (kubeadm requirement) ──────────────────────────
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

      # Reload containerd config (SystemdCgroup = true)
      systemctl restart containerd

      # ── 4. Install kubeadm / kubelet / kubectl ─────────────────────────
      log "Installing kubeadm v$${K8S_MINOR}..."
      curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$${K8S_MINOR}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
        https://pkgs.k8s.io/core:/stable:/v$${K8S_MINOR}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list
      apt-get update -q
      apt-get install -y kubelet kubeadm kubectl
      apt-mark hold kubelet kubeadm kubectl

      # ── 4b. Install AWS CLI v2 ─────────────────────────────────────────
      log "Installing AWS CLI v2..."
      apt-get install -y unzip
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
      unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2
      /tmp/awscliv2/aws/install
      rm -rf /tmp/awscliv2.zip /tmp/awscliv2
      systemctl enable kubelet

      # ── 5. kubeadm init ────────────────────────────────────────────────
      log "Running kubeadm init..."
      IMDS_TOKEN=""
      for i in $(seq 1 5); do
        IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
          -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && break
        log "IMDSv2 token attempt $${i}/5 failed, retrying in 5s..."
        sleep 5
      done
      [ -n "$${IMDS_TOKEN}" ] || { log "ERROR: failed to obtain IMDSv2 token after 5 attempts"; exit 1; }

      PRIVATE_IP=""
      for i in $(seq 1 5); do
        PRIVATE_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" \
          http://169.254.169.254/latest/meta-data/local-ipv4) && break
        log "IMDS private-ip attempt $${i}/5 failed, retrying in 5s..."
        sleep 5
      done
      [ -n "$${PRIVATE_IP}" ] || { log "ERROR: failed to fetch private IP from IMDS after 5 attempts"; exit 1; }
      sed -i "s|PRIVATE_IP|$${PRIVATE_IP}|" /etc/kubeadm/init-config.yaml

      PUBLIC_IP=""
      for i in $(seq 1 5); do
        PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" \
          http://169.254.169.254/latest/meta-data/public-ipv4) && break
        log "IMDS public-ip attempt $${i}/5 failed, retrying in 5s..."
        sleep 5
      done
      [ -n "$${PUBLIC_IP}" ] || { log "ERROR: failed to fetch public IP from IMDS after 5 attempts"; exit 1; }
      sed -i "s|PUBLIC_IP|$${PUBLIC_IP}|" /etc/kubeadm/init-config.yaml

      # Retrieve existing etcd encryption key from SSM, or generate + persist one.
      # CRITICAL: never regenerate — a new key makes existing encrypted Secrets unreadable.
      ENCRYPTION_KEY=$(aws ssm get-parameter \
        --name "$${SSM_ENC_KEY}" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --region "$${AWS_REGION}" 2>/dev/null || true)

      if [ -z "$${ENCRYPTION_KEY}" ] || [ "$${ENCRYPTION_KEY}" = "placeholder" ]; then
        log "Generating new etcd encryption key and storing in SSM..."
        ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
        aws ssm put-parameter \
          --name "$${SSM_ENC_KEY}" \
          --value "$${ENCRYPTION_KEY}" \
          --type SecureString \
          --overwrite \
          --region "$${AWS_REGION}"
      else
        log "Retrieved existing etcd encryption key from SSM."
      fi
      sed -i "s|ENCRYPTION_KEY_PLACEHOLDER|$${ENCRYPTION_KEY}|" \
        /etc/kubernetes/encryption-config.yaml

      # Replace the partial version ("1.32") with the exact installed version
      # kubeadm requires full SemVer (e.g. "1.32.3"); the APT package manager
      # selects the latest patch automatically so we ask kubeadm itself.
      KUBEADM_FULL_VERSION=$(kubeadm version -o short | sed 's/^v//')
      sed -i "s|kubernetesVersion: \"$${K8S_MINOR}\"|kubernetesVersion: \"$${KUBEADM_FULL_VERSION}\"|" \
        /etc/kubeadm/init-config.yaml
      kubeadm init --config /etc/kubeadm/init-config.yaml --upload-certs 2>&1

      # ── 6. Configure kubectl for ubuntu user ──────────────────────────
      log "Configuring kubectl for ubuntu user..."
      mkdir -p /home/ubuntu/.kube
      cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
      chown -R ubuntu:ubuntu /home/ubuntu/.kube

      export KUBECONFIG=/etc/kubernetes/admin.conf

      # ── 7. Install Calico CNI ─────────────────────────────────────────
      log "Installing Calico CNI v${calico_version}..."
      CALICO_OK=0
      for i in $(seq 1 5); do
        kubectl apply -f \
          "https://raw.githubusercontent.com/projectcalico/calico/v${calico_version}/manifests/calico.yaml" \
          && { CALICO_OK=1; break; } \
          || { log "Calico apply attempt $${i}/5 failed, retrying in 15s..."; sleep 15; }
      done
      [ $${CALICO_OK} -eq 1 ] || { log "ERROR: Calico CNI installation failed after 5 attempts."; exit 1; }

      # ── 8. Wait for control-plane to be Ready ─────────────────────────
      log "Waiting for control-plane node to be Ready..."
      for i in $(seq 1 30); do
        STATUS=$(kubectl get node --no-headers 2>/dev/null | awk '{print $2}' | head -1)
        [ "$${STATUS}" = "Ready" ] && break
        log "  node status: $${STATUS:-unknown} (attempt $${i}/30)"
        sleep 10
      done

      # ── 9. Write join command to SSM ──────────────────────────────────
      log "Writing join command to SSM..."
      JOIN_CMD=$(kubeadm token create --print-join-command) \
        || { log "ERROR: kubeadm token create failed"; exit 1; }
      [[ "$${JOIN_CMD}" == kubeadm\ join* ]] \
        || { log "ERROR: unexpected join command output: $${JOIN_CMD}"; exit 1; }
      aws ssm put-parameter \
        --name "$${SSM_JOIN}" \
        --value "$${JOIN_CMD}" \
        --type SecureString \
        --overwrite \
        --region "$${AWS_REGION}"

      # ── 10. Write kubeconfig to SSM (for bastion) ──────────────────────
      log "Writing kubeconfig to SSM..."
      KUBE_CONTENT=$(cat /etc/kubernetes/admin.conf)
      aws ssm put-parameter \
        --name "$${SSM_KUBE}" \
        --value "$${KUBE_CONTENT}" \
        --type SecureString \
        --tier Advanced \
        --overwrite \
        --region "$${AWS_REGION}"

      log "Control-plane bootstrap COMPLETE."

runcmd:
  - /usr/local/bin/k8s-bootstrap-control-plane.sh > /var/log/k8s-bootstrap.log 2>&1
