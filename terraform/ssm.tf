# ---------------------------------------------------------------------------
# SSM Parameter Store — placeholder entries created at apply time.
# The control-plane cloud-init overwrites these with real values after
# kubeadm init completes.  Workers poll until the join command appears.
# ---------------------------------------------------------------------------



resource "aws_ssm_parameter" "join_command" {
  name        = local.ssm_join_param
  type        = "SecureString"
  value       = "placeholder"     # overwritten by control-plane bootstrap script
  description = "kubeadm join command written by the control-plane node"
  #overwrite   = true   # remove: deprecated in AWS provider 5.4

  lifecycle {
    ignore_changes = [value]      # Terraform must not clobber what cloud-init writes
  }
}

resource "aws_ssm_parameter" "kubeconfig" {
  name        = local.ssm_kubeconfig_param
  type        = "SecureString"
  value       = "placeholder"
  description = "admin kubeconfig written by the control-plane node"
  tier        = "Advanced"   # kubeadm admin.conf with RSA-2048 certs is ~4-5 KB; Standard limit is 4 KB
  overwrite   = true # remove: deprecated in AWS provider 5.4

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "encryption_key" {
  name        = local.ssm_encryption_key_param
  type        = "SecureString"
  value       = "placeholder"
  description = "etcd encryption key — generated on first CP boot, never regenerated"
  overwrite   = true

  lifecycle {
    ignore_changes = [value]
  }
}
