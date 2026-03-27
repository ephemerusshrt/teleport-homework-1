# ---------------------------------------------------------------------------
# NLB security group — controls inbound public traffic
# ---------------------------------------------------------------------------
resource "aws_security_group" "nlb" {
  name        = "${local.cluster_name}-nlb-sg"
  description = "NLB: allow HTTP and HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "NLB forwards only to instances within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  tags = { Name = "${local.cluster_name}-nlb-sg" }
}

# ---------------------------------------------------------------------------
# K8s nodes security group — applied to control-plane and all workers
# ---------------------------------------------------------------------------
resource "aws_security_group" "k8s_nodes" {
  name        = "${local.cluster_name}-nodes-sg"
  description = "K8s nodes: internal cluster traffic + NodePorts from VPC CIDR only"
  vpc_id      = aws_vpc.main.id

  # All intra-cluster traffic (pod networking, API server, etcd, kubelet)
  ingress {
    description = "All intra-cluster traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Kubernetes API server — workers and pods within VPC (kubeadm join, in-cluster calls)
  ingress {
    description = "K8s API server from VPC"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  # Kubernetes API server — bastion / operator machine (kubectl from outside VPC)
  ingress {
    description = "K8s API server from admin CIDRs (kubectl)"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = local.allowed_admin_cidrs
  }

  # NodePort HTTP — only the VPC CIDR (covers the NLB) can reach it
  # NLB traffic originates from within the VPC CIDR block
  ingress {
    description = "NodePort HTTP from VPC (NLB only)"
    from_port   = local.nodeport_http
    to_port     = local.nodeport_http
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  # NodePort HTTPS — same restriction
  ingress {
    description = "NodePort HTTPS from VPC (NLB only)"
    from_port   = local.nodeport_https
    to_port     = local.nodeport_https
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  # SSH — optional, gated by allowed_admin_cidrs; SSM is preferred
  dynamic "ingress" {
    for_each = local.key_name != "" ? [1] : []
    content {
      description = "SSH (disabled when key_name is empty)"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = local.allowed_admin_cidrs
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.cluster_name}-nodes-sg" }
}
