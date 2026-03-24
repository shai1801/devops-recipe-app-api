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
      name      = "api"             #This is name of the cointainer#
      image     = var.ecr_app_image #This is path to ecr repo with app image,which is set in variables.tf and passed in through env vars in pipeline.#
      essential = true              #If this container fails, the task is considered failed.This container is essential for our application.#
      memory    = 256               #Memory limit for the container. Sum of memories for all the defined task must ont exceed memory defines for aws_ecs_task_definition#
      user      = "django-user"     #Name of the user to run the container. This is set to root because the app image needs to run some commands as root user.#
      environment = [


        {
          name  = "DJANGO_SECRET_KEY"
          value = var.django_secret_key
        },
        {
          name  = "DB_HOST"
          value = aws_db_instance.main.address
        },
        {
          name  = "DB_NAME"
          value = aws_db_instance.main.db_name
        },
        {
          name  = "DB_USER"
          value = aws_db_instance.main.username
        },

        {
          name  = "DB_PASS"
          value = aws_db_instance.main.password
        },
        {
          name  = "ALLOWED_HOSTS"
          value = "*"
        }

      ]

      mountPoints = [
        {
          readOnly      = false
          containerPath = "/vol/web/static"
          sourceVolume  = "static"
        }
      ]

      logConfiguration = {

        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_task_logs.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "api"
        }
      }
    },
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


#This seucrity group manages the rules for our service.And then we have assigned this to main VPC
#In this security group we have defined rules for outbound access as well as inbound access.
resource "aws_security_group" "ecs_services" {

  description = "Security group for ECS services"
  name        = "${local.prefix}-ecs-service"
  vpc_id      = aws_vpc.main.id

  # Outbound access to endpoints. This defines outbound access to port 443 for all the IP addresses.
  #This means that container will be able to access services like cloudwatch, S3 running on port 443.
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  #RDS conntectivity. Here CIDR block has been narrowed down to private subnets only, which means that only resources running in private subnets will be able to access the database. This is a security best practice to limit the exposure of the database.

  egress {
    from_port = 5432
    to_port   = 5432
    protocol  = "tcp"
    cidr_blocks = [
      aws_subnet.private_a.cidr_block,
      aws_subnet.private_b.cidr_block
    ]

  }

  #HTTP Inbound access, which allows incoming traffic on port 8000 from any IP address.
  #This is necessary for our application to be accessible from the internet.
  #If  you check above its the same port on which the proxy container listens,
  #so this rule allows external traffic to reach the proxy container, which then forwards it to the application container.

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]

  }
}

resource "aws_ecs_service" "api" {
  name                   = "${local.prefix}-api-service"
  cluster                = aws_ecs_cluster.main.name
  task_definition        = aws_ecs_task_definition.api.family
  desired_count          = 1
  launch_type            = "FARGATE"
  platform_version       = "1.4.0"
  enable_execute_command = true

  network_configuration {
    subnets          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_groups  = [aws_security_group.ecs_services.id]
    assign_public_ip = true #This is temporary till ALB is implemented.
  }
}
