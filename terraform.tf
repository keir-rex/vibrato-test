terraform {
    backend "s3" {
      region      = "ap-southeast-2"
      bucket      = "vibrato-test-app-state"
      key         = "vibrato-test-app.tfstate"
      encrypt     = 1
      kms_key_id  = "arn:aws:kms:ap-southeast-2:501393350350:key/3560f742-7edb-44da-90c6-a6892bc95caa"
    }
}

provider "aws" {}



##################################################################################################################################
########################### Data blocks ##########################################################################################

# Data block for current region
data "aws_region" "current" {}

# Data block for retrieving list of availability zones dynamically
data "aws_availability_zones" "available" {}

# The block below is required to later configure s3 bucket to receive ALB
data "aws_elb_service_account" "main" {}

##################################################################################################################################
########################### Variable blocks ######################################################################################

# Define a block of IPs sufficiently large for the purpose of this project
# /21 will give us 2048 IPs which we can divide into 3 private / 3 public subnets (one for each per AZ)
# We'll launch our load balancers in the public subnets and the rest of our stack in the private subnets
variable "cidr_block" {
  type    = "string"
  default = "10.0.0.0/21"
}

# The calculated private subnets (510 addresses each)
variable "private_subnets" {
  type    = "list"
  default = ["10.0.0.0/23","10.0.2.0/23","10.0.4.0/23"]
}

# The calculated public subnets (126 addresses each)
variable "public_subnets" {
  type    = "list"
  default = ["10.0.6.0/25","10.0.6.128/25","10.0.7.0/25"]
}

variable "rds_engine" {
  type = "string"
  default = "aurora-postgresql"
}

variable "rds_version" {
  type = "string"
  default = "9.6.8"
}

variable "rds_instance_size" {
  type = "string"
  default = "db.r4.large"
}

variable "repository_uri" {
  type = "string"
  default = "vibrato/techtestapp"
}

##################################################################################################################################
########################### Secrets Setup ########################################################################################

# TODO; it doesn't look like we'll need this but I'll leave it here for now

# resource "aws_secretsmanager_secret" "docker_pull_secret" {
#   name = "docker_pull_secret"
# }

# resource "aws_secretsmanager_secret_version" "docker_pull_secret" {
#   secret_id     = "${aws_secretsmanager_secret.docker_pull_secret.id}"
#   secret_string = "${file("")}"
# }

##################################################################################################################################
########################### VPC Setup ############################################################################################

resource "aws_vpc" "main" {
  cidr_block = "${var.cidr_block}"
  tags {
    Name = "vibrato_techtest-vpc-main"
    project = "vibrato-techtest"
  }
}

# Create a group of public subnets; one for each AZ within the region we launched our VPC
resource "aws_subnet" "public" {
  count      = "${length(var.public_subnets)}"
  vpc_id     = "${aws_vpc.main.id}"
  cidr_block = "${var.public_subnets[count.index]}"
  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
  
  tags {
    Name = "vibrato_techtest-subnet-public-${data.aws_availability_zones.available.names[count.index]}"
    project = "vibrato-techtest"
  }
}

# Create a group of private subnets; one for each AZ within the region we launched our VPC
resource "aws_subnet" "private" {
  count      = "${length(var.private_subnets)}"
  vpc_id     = "${aws_vpc.main.id}"
  cidr_block = "${var.private_subnets[count.index]}"
  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
  
  tags {
    Name = "vibrato_techtest-subnet-private-${data.aws_availability_zones.available.names[count.index]}"
    project = "vibrato-techtest"
  }
}

resource "aws_internet_gateway" "main_igw" {
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name = "vibrato_techtest-igw"
    project = "vibrato-techtest"
  }
}

resource "aws_eip" "nat_eip" {
  count      = 3
  vpc        = true
  depends_on = ["aws_internet_gateway.main_igw"]
}

resource "aws_nat_gateway" "nat" {
  count         = 3
  allocation_id = "${element(aws_eip.nat_eip.*.id, count.index)}"
  subnet_id     = "${element(aws_subnet.public.*.id, count.index)}"
  depends_on    = ["aws_internet_gateway.main_igw"]

  tags {
    Name        = "vibrato_techtest-${element(data.aws_availability_zones.available.names, count.index)}-nat" # TODO; make sure this follows a concise convention
    project     = "vibrato-techtest" # TODO; parameterize this
  }
}

# Routing table for private subnet
resource "aws_route_table" "private" {
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name        = "vibrato_techtest-private_route_table" # TODO; make sure this follows a concise convention
    project     = "vibrato-techtest" # TODO; parameterize this
  }
}

# Routing table for public subnet
resource "aws_route_table" "public" {
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name        = "vibrato_techtest-public_route_table" # TODO; make sure this follows a concise convention
    project     = "vibrato-techtest" # TODO; parameterize this
  }
}

resource "aws_route" "public_internet_gateway_route" {
  route_table_id         = "${aws_route_table.public.id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.main_igw.id}"
}

resource "aws_route" "private_nat_gateway_route" {
  route_table_id         = "${aws_route_table.private.id}"
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = "${element(aws_nat_gateway.nat.*.id, count.index)}"
}

# Route table associations
resource "aws_route_table_association" "public" {
  count          = "${length(var.public_subnets)}"
  subnet_id      = "${element(aws_subnet.public.*.id, count.index)}"
  route_table_id = "${aws_route_table.public.id}"
}

resource "aws_route_table_association" "private" {
  count           = "${length(var.private_subnets)}"
  subnet_id       = "${element(aws_subnet.private.*.id, count.index)}"
  route_table_id  = "${aws_route_table.private.id}"
}

##################################################################################################################################
########################### DB Setup #############################################################################################

resource "aws_db_subnet_group" "postgres_db_cluster_subnet_group" {
  name       = "vibrato_techtest-db_subnet_group"
  subnet_ids = ["${aws_subnet.private.*.id}"]

  tags {
    Name = "vibrato_techtest-db_subnet_group-postgres_db_cluster_subnet_group"
    project = "vibrato-techtest"
  }
}

resource "aws_rds_cluster" "postgres_db_cluster" {
  cluster_identifier      = "vibrato-techtest-postgres-db-cluster"
  engine                  = "${var.rds_engine}"
  engine_version          = "${var.rds_version}"
  availability_zones      = ["${data.aws_availability_zones.available.names[0]}","${data.aws_availability_zones.available.names[1]}","${data.aws_availability_zones.available.names[2]}"]
  db_subnet_group_name    = "${aws_db_subnet_group.postgres_db_cluster_subnet_group.name}"
  database_name           = "techtestdb"
  master_username         = "foo"
  master_password         = "${file("secret_postgres_password")}"
  skip_final_snapshot     = true
  
  tags {
    Name = "vibrato_techtest-rds-postgres_db_cluster"
    project = "vibrato-techtest"
  }
}

resource "aws_rds_cluster_instance" "postgres_db_instances" {
  count                 = 3
  identifier            = "vibrato-techtest-postgres-db-instance-${count.index}"
  cluster_identifier    = "${aws_rds_cluster.postgres_db_cluster.id}"
  db_subnet_group_name  = "${aws_db_subnet_group.postgres_db_cluster_subnet_group.name}"
  instance_class        = "${var.rds_instance_size}"
  engine                = "${var.rds_engine}"
  engine_version        = "${var.rds_version}"
  
  tags {
    Name = "vibrato_techtest-rds-postgres_db_instance-${data.aws_availability_zones.available.names[count.index]}"
    project = "vibrato-techtest"
  }
}

##################################################################################################################################
########################### Load Balancer ########################################################################################

# TODO review this to close down traffic to follow principle of least privilege
resource "aws_security_group" "allow_all" {
  name        = "allow_all"
  description = "Allow all inbound traffic"
  vpc_id      = "${aws_vpc.main.id}"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }
}

resource "aws_s3_bucket" "alb_logs" {
  bucket = "vibrato-techtest-alb-logs"
  acl    = "private"
  force_destroy = true # TODO; this is useful for development but should be removed or optional depending on, say: "${var.env == "production" ? false : true}"
  policy = <<EOF
{
  "Id": "Policy",
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:PutObject"
      ],
      "Effect": "Allow",
      "Resource": "arn:aws:s3:::vibrato-techtest-alb-logs/*",
      "Principal": {
        "AWS": [
          "${data.aws_elb_service_account.main.arn}"
        ]
      }
    }
  ]
}
EOF

  tags {
    Name        = "vibrato_techtest-s3-alb_logs"
    project     = "vigrato-techtest"
  }
}

resource "aws_alb_target_group" "load_balancer-target_group" {
  name     = "vibrato-techtest-alb-target-grp"
  port     = 3000 # todo parameterise this
  protocol = "HTTP"
  vpc_id   = "${aws_vpc.main.id}"
  target_type   = "ip"
}

resource "aws_lb" "load_balancer" {
  name               = "vibrato-techtest-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["${aws_security_group.allow_all.id}"]
  subnets            = ["${aws_subnet.public.*.id}"]

  # Uncomment after development as it makes it easier to iterate 
  # access_logs {
  #   bucket  = "${aws_s3_bucket.alb_logs.bucket}"
  #   prefix  = "vibrato_techtest"
  #   enabled = true
  # }

  tags {
    Name        = "vibrato_techtest-s3-alb_logs"
    project     = "vigrato-techtest"
  }
}

resource "aws_alb_listener" "load_balancer_listener" {
  load_balancer_arn = "${aws_lb.load_balancer.arn}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = "${aws_alb_target_group.load_balancer-target_group.arn}"
  }
}

##################################################################################################################################
########################### ECS Preconfig ########################################################################################


# IAM service role
data "aws_iam_policy_document" "ecs_service_role" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_role" {
  name               = "ecs_role"
  assume_role_policy = "${data.aws_iam_policy_document.ecs_service_role.json}"
}

data "aws_iam_policy_document" "ecs_service_policy" {
  statement {
    effect = "Allow"
    resources = ["*"]
    actions = [
      "elasticloadbalancing:Describe*",
      "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
      "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
      "ec2:Describe*",
      "ec2:AuthorizeSecurityGroupIngress"
    ]
  }
}

# ecs service scheduler role
resource "aws_iam_role_policy" "ecs_service_role_policy" {
  name   = "ecs_service_role_policy"
  policy = "${data.aws_iam_policy_document.ecs_service_policy.json}"
  role   = "${aws_iam_role.ecs_role.id}"
}

# role that the Amazon ECS container agent and the Docker daemon can assume
resource "aws_iam_role" "ecs_execution_role" {
  name               = "ecs_task_execution_role"
  assume_role_policy = "${file("${path.module}/policies/ecs-task-execution-role.json")}"
}

resource "aws_iam_role_policy" "ecs_execution_role_policy" {
  name   = "ecs_execution_role_policy"
  policy = "${file("${path.module}/policies/ecs-execution-role-policy.json")}"
  role   = "${aws_iam_role.ecs_execution_role.id}"
}

##################################################################################################################################
########################### ECS Setup ############################################################################################

data "aws_ecr_repository" "techtest_app_repository" {
  name = "techtestapp"
}

data "template_file" "task_definition" {
  template = "${file("${path.module}/task-definitions/techtest-frontend-task.json")}"

  vars {
    image = "${aws_ecr_repository.techtest_app_repository.repository_url}"
  }
  depends_on      = ["aws_alb_listener.load_balancer_listener"]
}

 data "aws_ecs_task_definition" "ecs_task" {
  task_definition = "${aws_ecs_task_definition.ecs_task.family}"
 }

resource "aws_ecs_cluster" "cluster" {
  name = "vibrato_techtest-ecs-cluster"
  tags {
    Name = "vibrato_techtest-ecs-cluster"
    project = "vibrato-techtest"
  }
}

resource "aws_ecr_repository" "techtest_app_repository" {
  name = "techtestapp"
}

resource "aws_ecs_task_definition" "ecs_task" {
  family                    = "vibrato_techtest-ecs_task"
  container_definitions     = "${data.template_file.task_definition.rendered}"
  cpu                       = 256 #TODO Parameterize cpu/memory
  memory                    = 512
  network_mode              = "awsvpc"
  requires_compatibilities  = ["FARGATE"]
  execution_role_arn        = "${aws_iam_role.ecs_execution_role.arn}"
}

resource "aws_ecs_service" "techtest_app_frontend_service" {
  name            = "vibrato_techtest-ecs_service"
  cluster         = "${aws_ecs_cluster.cluster.id}"
  task_definition = "${aws_ecs_task_definition.ecs_task.family}:${max("${aws_ecs_task_definition.ecs_task.revision}", "${data.aws_ecs_task_definition.ecs_task.revision}")}"
  desired_count   = 3
  launch_type     = "FARGATE"
  depends_on      = ["aws_alb_listener.load_balancer_listener"]

  load_balancer {
    target_group_arn = "${aws_alb_target_group.load_balancer-target_group.arn}"
    container_name   = "techtestapp"
    container_port   = 3000 # todo parameterise this
  }

  network_configuration {
    subnets = ["${aws_subnet.private.*.id}"]
    security_groups = ["${aws_security_group.allow_all.id}"]
  }
}

##################################################################################################################################
########################### Codebuild Preconfig ###################################################################################

# Below is derived with a bit of help from here: https://thecode.pub/easy-deploy-your-docker-applications-to-aws-using-ecs-and-fargate-a988a1cc842f

resource "aws_s3_bucket" "codebuild" {
  bucket = "vibrato-techtest-codebuild"
  acl    = "private"
  force_destroy = true # TODO; this is useful for development but should be removed or optional depending on, say: "${var.env == "production" ? false : true}"
}

resource "aws_iam_role" "codebuild_role" {
  name = "codebuild-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codebuild_policy" {
  role = "${aws_iam_role.codebuild_role.name}"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": [
        "*"
      ],
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "ecr:GetAuthorizationToken",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage",
        "ecs:RunTask",
        "iam:PassRole"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNetworkInterface",
        "ec2:DescribeDhcpOptions",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeVpcs",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:List*",
        "s3:PutObject",
        "iam:PassRole"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": [
        "${aws_s3_bucket.codebuild.arn}",
        "${aws_s3_bucket.codebuild.arn}/*",
        "${aws_s3_bucket.codepipeline.arn}",
        "${aws_s3_bucket.codepipeline.arn}/*"
      ]
    }
  ]
}
POLICY
}

##################################################################################################################################
########################### Codepipeline Preconfig ###################################################################################

resource "aws_s3_bucket" "codepipeline" {
  bucket = "vibrato-techtest-codepipeline"
  acl    = "private"
  force_destroy = true # TODO; this is useful for development but should be removed or optional depending on, say: "${var.env == "production" ? false : true}"
}

resource "aws_iam_role" "codepipeline_role" {
  name = "vibrato_techtest-codepipeline_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codepipeline.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "vibrato_techtest-codepipeline_policy"
  role = "${aws_iam_role.codepipeline_role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:PutObject",
        "ecs:*",
        "events:DescribeRule",
        "events:DeleteRule",
        "events:ListRuleNamesByTarget",
        "events:ListTargetsByRule",
        "events:PutRule",
        "events:PutTargets",
        "events:RemoveTargets",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfiles",
        "iam:ListRoles",
        "logs:CreateLogGroup",
        "logs:DescribeLogGroups",
        "logs:FilterLogEvents",
        "iam:PassRole"
      ],
      "Resource": [
        "${aws_s3_bucket.codepipeline.arn}",
        "${aws_s3_bucket.codepipeline.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "ecr:GetAuthorizationToken",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage",
        "ecs:RunTask",
        "iam:PassRole",
        "ecs:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

##################################################################################################################################
########################### Pipeline config ######################################################################################

data "template_file" "buildspec" {
  template = "${file("${path.module}/build-specifications/buildspec.yaml")}"

  vars {
    repository_url     = "${aws_ecr_repository.techtest_app_repository.repository_url}"
    region             = "${data.aws_region.current.name}"
    cluster_name       = "${aws_ecs_cluster.cluster.name}"
    subnet_ids         = "${join(",", aws_subnet.private.*.id)}"
    security_group_ids = "${aws_security_group.allow_all.id}" # TODO; lockdown security groups
  }
}

resource "aws_codebuild_project" "container_build" {
  name          = "vibrato_techtest-container_build"
  build_timeout = "10"
  service_role  = "${aws_iam_role.codebuild_role.arn}"

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    // https://docs.aws.amazon.com/codebuild/latest/userguide/build-env-ref-available.html
    image           = "aws/codebuild/docker:17.09.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "${data.template_file.buildspec.rendered}"
  }
}


resource "aws_codepipeline" "container_build_pipeline" {
  name     = "vibrato_techtest-container_build_pipeline"
  role_arn = "${aws_iam_role.codepipeline_role.arn}"

  artifact_store {
    location = "${aws_s3_bucket.codepipeline.bucket}"
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source"]

      configuration {
        Owner      = "keir-rex" # TODO; parameterize this
        Repo       = "TechTestApp"
        Branch     = "master"
        OAuthToken = "${file("secret_github")}"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source"]
      output_artifacts = ["imagedefinitions"]

      configuration {
        ProjectName = "${aws_codebuild_project.container_build.name}"
      }
    }
  }

  stage {
    name = "Production"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["imagedefinitions"]
      version         = "1"

      configuration {
        ClusterName = "${aws_ecs_cluster.cluster.name}"
        ServiceName = "${aws_ecs_service.techtest_app_frontend_service.name}"
        FileName    = "imagedefinitions.json"
      }
    }
  }
}