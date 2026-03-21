###############
##ECS Cluster##
###############

resource "aws_iam_policy" "task_execution_role_policy" {
  name        = "${local.prefix}-task-exec-role-policy"
  path        = "/"
  description = "Allow ECS to retrieve images and add to logs."
  policy      = file("./templates/ecs/task-execution-role-policy.json")
}

resource "aws_iam_role" "task_execution_role" {
  name               = "${local.prefix}-task-execution-role"
  assume_role_policy = file("./templates/ecs/task-assume-role-policy.json")
}

resource "aws_iam_role_policy_attachment" "task_execution_role" {
  role       = aws_iam_role.task_execution_role.name
  policy_arn = aws_iam_policy.task_execution_role_policy.arn
}


resource "aws_iam_role" "app_task" {
  name               = "${local.prefix}-app-task"
  assume_role_policy = file("./templates/ecs/task-assume-role-policy.json")
}

resource "aws_iam_policy" "task_ssm_policy" {
  name        = "${local.prefix}-task-ssm-role-policy"
  path        = "/"
  description = "Policy to allow System Manager to execute in container"
  policy      = file("./templates/ecs/task-ssm-policy.json")
}

resource "aws_iam_role_policy_attachment" "task_ssm_policy" {
  role       = aws_iam_role.app_task.name
  policy_arn = aws_iam_policy.task_ssm_policy.arn
}

resource "aws_cloudwatch_log_group" "ecs_task_logs" {
  name = "${local.prefix}-api"

}

resource "aws_ecs_cluster" "main" {
  name = "${local.prefix}-cluster"
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.prefix}-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  execution_role_arn = aws_iam_role.task_execution_role.arn
  task_role_arn      = aws_iam_role.app_task.arn

  container_definitions = jsonencode([
    {
      name      = "proxy"             #This is name of the cointainer#
      image     = var.ecr_proxy_image #This is path to ecr repo with proxy image,which is set in variables.tf and passed in through env vars in pipeline.#
      essential = true                #If this container fails, the task is considered failed.This container is essential for our application.#
      memory    = 256                 #Memory limit for the container. Sum of memories for all the defined task must ont exceed memory defines for aws_ecs_task_definition#
      user      = "nginx"             #Name of the user to run the container. This is set to nginx because the proxy image is based on nginx image.#
      portMappings = [
        {
          containerPort = 8000 #Port on which the container listens. This should match the port defined in the proxy configuration.#
          hostPort      = 8000 #
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "APP_HOST"
          value = "127.0.0.1"
        }
      ]

      mountPoints = [
        {
          readOnly      = true
          containerPath = "/var/static"
          sourceVolume  = "static"
        }
      ]

      logConfiguration = {

        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_task_logs.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "proxy"
        }
      }
    }
  ])

  volume {
    name = "status"
  }

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}
