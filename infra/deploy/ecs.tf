###############
##ECS Cluster##
###############

resource "aws_ecs_cluster" "main" {
  name = "${local.prefix}-cluster"
}
