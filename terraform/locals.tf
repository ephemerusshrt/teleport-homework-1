# All values are driven from config.yaml — do not hard-code here.
locals {
  config = yamldecode(file("${path.root}/../config.yaml"))

  # Cluster
  cluster_name = local.config.cluster.name
  k8s_version  = local.config.cluster.kubernetes_version
  pod_cidr     = local.config.cluster.pod_cidr
  service_cidr = local.config.cluster.service_cidr
  dns_domain   = local.config.cluster.dns_domain

  # AWS
  aws_region   = local.config.aws.region
  azs          = local.config.aws.availability_zones
  vpc_cidr     = local.config.aws.vpc.cidr
  public_cidrs = local.config.aws.vpc.public_subnet_cidrs

  # EC2
  key_name             = local.config.aws.ec2.key_name
  cp_instance_type     = local.config.aws.ec2.control_plane.instance_type
  cp_disk_size         = local.config.aws.ec2.control_plane.disk_size_gb
  worker_instance_type = local.config.aws.ec2.workers.instance_type
  worker_disk_size     = local.config.aws.ec2.workers.disk_size_gb
  worker_count         = local.config.aws.ec2.workers.count

  # Load balancer
  lb_name = local.config.aws.load_balancer.name

  # Security groups
  allowed_admin_cidrs = local.config.aws.security_groups.allowed_admin_cidrs
  nodeport_http       = local.config.aws.security_groups.nodeport_http
  nodeport_https      = local.config.aws.security_groups.nodeport_https

  # Nginx
  nginx_version  = local.config.nginx.version
  nginx_replicas = local.config.nginx.replicas

  # Calico
  calico_version = local.config.calico.version

  # Cert-manager
  cert_manager_version = local.config.cert_manager.version

  # Users — drives RBAC scripts
  users = local.config.users

  # SSM Parameter paths (written by control-plane, read by workers + bastion)
  ssm_join_param           = "/k8s/${local.cluster_name}/join-command"
  ssm_kubeconfig_param     = "/k8s/${local.cluster_name}/kubeconfig"
  ssm_encryption_key_param = "/k8s/${local.cluster_name}/encryption-key"

  common_tags = {
    Project     = local.cluster_name
    ManagedBy   = "terraform"
    Environment = "demo"
  }
}
