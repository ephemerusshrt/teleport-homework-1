# ---------------------------------------------------------------------------
# Network Load Balancer
# TCP passthrough — TLS terminates at nginx (self-signed cert stays intact)
# ---------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = local.lb_name
  internal           = false
  load_balancer_type = "network"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.nlb.id]

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true

  tags = { Name = local.lb_name }
}

# ---------------------------------------------------------------------------
# HTTP target group → NodePort 30080
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "http" {
  name                 = "${local.cluster_name}-http-tg"
  port                 = local.nodeport_http
  protocol             = "TCP"
  vpc_id               = aws_vpc.main.id
  target_type          = "instance"
  preserve_client_ip   = "false"

  health_check {
    # 2 passes × 10s interval = 20s to become healthy; same to become unhealthy.
    # Total worst-case failover window: ~20s.
    protocol            = "TCP"
    port                = local.nodeport_http
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = { Name = "${local.cluster_name}-http-tg" }
}

# ---------------------------------------------------------------------------
# HTTPS target group → NodePort 30443 (TCP passthrough — no ACM cert needed)
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "https" {
  name                 = "${local.cluster_name}-https-tg"
  port                 = local.nodeport_https
  protocol             = "TCP"
  vpc_id               = aws_vpc.main.id
  target_type          = "instance"
  preserve_client_ip   = "false"

  health_check {
    # 2 passes × 10s interval = 20s to become healthy; same to become unhealthy.
    # Total worst-case failover window: ~20s.
    protocol            = "TCP"
    port                = local.nodeport_https
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = { Name = "${local.cluster_name}-https-tg" }
}

# ---------------------------------------------------------------------------
# Listeners
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https.arn
  }
}
