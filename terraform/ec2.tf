# Latest Ubuntu 24.04 LTS AMI (amd64, hvm:ebs-ssd)
data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Control Plane node
# ---------------------------------------------------------------------------
resource "aws_instance" "control_plane" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = local.cp_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.k8s_node.name
  key_name               = local.key_name != "" ? local.key_name : null

  root_block_device {
    volume_size           = local.cp_disk_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = templatefile("${path.module}/cloud-init/control-plane.yaml.tpl", {
    cluster_name         = local.cluster_name
    k8s_version          = local.k8s_version
    calico_version       = local.calico_version
    pod_cidr             = local.pod_cidr
    service_cidr         = local.service_cidr
    dns_domain           = local.dns_domain
    aws_region           = local.aws_region
    ssm_join_param           = local.ssm_join_param
    ssm_kubeconfig_param     = local.ssm_kubeconfig_param
    ssm_encryption_key_param = local.ssm_encryption_key_param
  })

  tags = { Name = "${local.cluster_name}-control-plane" }

  # Ensure IAM profile and SSM params path are ready before boot
  depends_on = [
    aws_iam_instance_profile.k8s_node,
  ]
}

# ---------------------------------------------------------------------------
# Worker nodes
# ---------------------------------------------------------------------------
resource "aws_instance" "workers" {
  count = local.worker_count

  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = local.worker_instance_type
  subnet_id              = aws_subnet.public[count.index % length(aws_subnet.public)].id  # only for this teleport demo project for debugging purposes.   wouldn't happen in a production environment..
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.k8s_node.name
  key_name               = local.key_name != "" ? local.key_name : null

  root_block_device {
    volume_size           = local.worker_disk_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = templatefile("${path.module}/cloud-init/worker.yaml.tpl", {
    cluster_name    = local.cluster_name
    k8s_version     = local.k8s_version
    aws_region      = local.aws_region
    ssm_join_param  = local.ssm_join_param
  })

  tags = { Name = "${local.cluster_name}-worker-${count.index + 1}" }

  depends_on = [
    aws_iam_instance_profile.k8s_node,
    aws_instance.control_plane,
  ]
}

# ---------------------------------------------------------------------------
# NLB target group attachments — both workers serve NodePort traffic
# ---------------------------------------------------------------------------
resource "aws_lb_target_group_attachment" "http" {
  count            = length(aws_instance.workers)
  target_group_arn = aws_lb_target_group.http.arn
  target_id        = aws_instance.workers[count.index].id
  port             = local.nodeport_http
}

resource "aws_lb_target_group_attachment" "https" {
  count            = length(aws_instance.workers)
  target_group_arn = aws_lb_target_group.https.arn
  target_id        = aws_instance.workers[count.index].id
  port             = local.nodeport_https
}
