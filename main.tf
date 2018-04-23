locals {
  create_alb          = "${var.load_balancer_arn == "" && var.create_alb}"
  create_logs         = "${var.log_bucket_name != ""}"
  create_alb_logs     = "${local.create_alb && local.create_logs}"
  create_alb_no_logs  = "${local.create_alb && !local.create_logs}"
  load_balancer_arn   = "${local.create_alb ? local.create_alb_logs ? join(",", aws_lb.application.*.arn) : join(",", aws_lb.application_no_logs.*.arn) : var.load_balancer_arn}"
  lb_module           = "${local.create_alb_no_logs ? "aws_lb.application_no_logs.arn" : "aws_lb.application"}" 
   # Hack to replace dynamic dependency management
  target_groups_count = "${var.target_groups_count * signum(local.create_alb_logs ? length(aws_lb.application.*.arn) : local.create_alb_logs ? length(aws_lb.application_no_logs.*.arn) : 0)}"
}

resource "aws_lb" "application" {
  count                      = "${local.create_alb_logs ? 1 : 0}"
  load_balancer_type         = "application"
  name                       = "${var.load_balancer_name}"
  internal                   = "${var.load_balancer_is_internal}"
  security_groups            = ["${var.security_groups}"]
  subnets                    = ["${var.subnets}"]
  idle_timeout               = "${var.idle_timeout}"
  enable_deletion_protection = "${var.enable_deletion_protection}"
  enable_http2               = "${var.enable_http2}"
  ip_address_type            = "${var.ip_address_type}"
  tags                       = "${merge(var.tags, map("Name", var.load_balancer_name))}"

  access_logs {
    enabled = true
    bucket  = "${var.log_bucket_name}"
    prefix  = "${var.log_location_prefix}"
  }

  timeouts {
    create = "${var.load_balancer_create_timeout}"
    delete = "${var.load_balancer_delete_timeout}"
    update = "${var.load_balancer_update_timeout}"
  }
}

resource "aws_lb" "application_no_logs" {
  count                      = "${local.create_alb_no_logs ? 1 : 0}"
  load_balancer_type         = "application"
  name                       = "${var.load_balancer_name}"
  internal                   = "${var.load_balancer_is_internal}"
  security_groups            = ["${var.security_groups}"]
  subnets                    = ["${var.subnets}"]
  idle_timeout               = "${var.idle_timeout}"
  enable_deletion_protection = "${var.enable_deletion_protection}"
  enable_http2               = "${var.enable_http2}"
  ip_address_type            = "${var.ip_address_type}"
  tags                       = "${merge(var.tags, map("Name", var.load_balancer_name))}"

  timeouts {
    create = "${var.load_balancer_create_timeout}"
    delete = "${var.load_balancer_delete_timeout}"
    update = "${var.load_balancer_update_timeout}"
  }
}

resource "aws_lb_target_group" "main" {
  name                 = "${lookup(var.target_groups[count.index], "name")}"
  vpc_id               = "${var.vpc_id}"
  port                 = "${lookup(var.target_groups[count.index], "backend_port")}"
  protocol             = "${upper(lookup(var.target_groups[count.index], "backend_protocol"))}"
  deregistration_delay = "${lookup(var.target_groups[count.index], "deregistration_delay", lookup(var.target_groups_defaults, "deregistration_delay"))}"
  target_type          = "${lookup(var.target_groups[count.index], "target_type", lookup(var.target_groups_defaults, "target_type"))}"

  health_check {
    interval            = "${lookup(var.target_groups[count.index], "health_check_interval", lookup(var.target_groups_defaults, "health_check_interval"))}"
    path                = "${lookup(var.target_groups[count.index], "health_check_path", lookup(var.target_groups_defaults, "health_check_path"))}"
    port                = "${lookup(var.target_groups[count.index], "health_check_port", lookup(var.target_groups_defaults, "health_check_port"))}"
    healthy_threshold   = "${lookup(var.target_groups[count.index], "health_check_healthy_threshold", lookup(var.target_groups_defaults, "health_check_healthy_threshold"))}"
    unhealthy_threshold = "${lookup(var.target_groups[count.index], "health_check_unhealthy_threshold", lookup(var.target_groups_defaults, "health_check_unhealthy_threshold"))}"
    timeout             = "${lookup(var.target_groups[count.index], "health_check_timeout", lookup(var.target_groups_defaults, "health_check_timeout"))}"
    protocol            = "${upper(lookup(var.target_groups[count.index], "healthcheck_protocol", lookup(var.target_groups[count.index], "backend_protocol")))}"
    matcher             = "${lookup(var.target_groups[count.index], "health_check_matcher", lookup(var.target_groups_defaults, "health_check_matcher"))}"
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = "${lookup(var.target_groups[count.index], "cookie_duration", lookup(var.target_groups_defaults, "cookie_duration"))}"
    enabled         = "${lookup(var.target_groups[count.index], "stickiness_enabled", lookup(var.target_groups_defaults, "stickiness_enabled"))}"
  }

  tags       = "${merge(var.tags, map("Name", lookup(var.target_groups[count.index], "name")))}"
  count      = "${local.target_groups_count}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "frontend_http_tcp" {
  load_balancer_arn = "${local.load_balancer_arn}"
  port              = "${lookup(var.http_tcp_listeners[count.index], "port")}"
  protocol          = "${lookup(var.http_tcp_listeners[count.index], "protocol")}"
  count             = "${var.http_tcp_listeners_count}"

  default_action {
    target_group_arn = "${aws_lb_target_group.main.*.id[lookup(var.http_tcp_listeners[count.index], "target_group_index", 0)]}"
    type             = "forward"
  }
}

resource "aws_lb_listener" "frontend_https" {
  load_balancer_arn = "${local.load_balancer_arn}"
  port              = "${lookup(var.https_listeners[count.index], "port")}"
  protocol          = "HTTPS"
  certificate_arn   = "${lookup(var.https_listeners[count.index], "certificate_arn")}"
  ssl_policy        = "${lookup(var.https_listeners[count.index], "ssl_policy", var.listener_ssl_policy_default)}"
  count             = "${var.https_listeners_count}"

  default_action {
    target_group_arn = "${aws_lb_target_group.main.*.id[lookup(var.https_listeners[count.index], "target_group_index", 0)]}"
    type             = "forward"
  }
}

resource "aws_lb_listener_certificate" "https_listener" {
  listener_arn    = "${aws_lb_listener.frontend_https.*.arn[lookup(var.extra_ssl_certs[count.index], "https_listener_index")]}"
  certificate_arn = "${lookup(var.extra_ssl_certs[count.index], "certificate_arn")}"
  count           = "${var.extra_ssl_certs_count}"
}
