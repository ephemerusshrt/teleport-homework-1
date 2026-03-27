output "nlb_dns_name" {
  description = "Public DNS name of the Network Load Balancer"
  value       = aws_lb.main.dns_name
}

output "control_plane_instance_id" {
  description = "EC2 instance ID of the control-plane node"
  value       = aws_instance.control_plane.id
}

output "control_plane_public_ip" {
  description = "Public IP of the control-plane node (used to patch kubeconfig server address)"
  value       = aws_instance.control_plane.public_ip
}

output "worker_instance_ids" {
  description = "EC2 instance IDs of the worker nodes"
  value       = aws_instance.workers[*].id
}

output "ssm_kubeconfig_param" {
  description = "SSM Parameter path — fetch kubeconfig with: aws ssm get-parameter --name <value> --with-decryption"
  value       = local.ssm_kubeconfig_param
}

output "ssm_join_param" {
  description = "SSM Parameter path storing the kubeadm join command"
  value       = local.ssm_join_param
}

output "cluster_name" {
  description = "Kubernetes cluster name"
  value       = local.cluster_name
}

output "aws_region" {
  description = "AWS region"
  value       = local.aws_region
}
