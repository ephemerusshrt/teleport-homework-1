# ---------------------------------------------------------------------------
# IAM instance profile — attached to ALL k8s nodes
# Grants: SSM Session Manager + SSM Parameter Store read/write for bootstrap
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "k8s_node" {
  name               = "${local.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# SSM Session Manager — eliminates need for SSH/open port 22
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.k8s_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# SSM Parameter Store — scoped to this cluster's prefix only
data "aws_iam_policy_document" "ssm_params" {
  statement {
    sid    = "ReadWriteClusterParams"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:DeleteParameter",
    ]
    resources = [
      "arn:aws:ssm:${local.aws_region}:*:parameter/k8s/${local.cluster_name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "ssm_params" {
  name   = "${local.cluster_name}-ssm-params"
  role   = aws_iam_role.k8s_node.id
  policy = data.aws_iam_policy_document.ssm_params.json
}

resource "aws_iam_instance_profile" "k8s_node" {
  name = "${local.cluster_name}-node-profile"
  role = aws_iam_role.k8s_node.name
}
