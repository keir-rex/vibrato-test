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
  master_password         = "${file("secret_password")}"
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
########################### ECS Setup ############################################################################################

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
  family                = "vibrato_techtest-ecs_task"
  container_definitions = "${file("task-definitions/techtest-frontend-task.json")}"
}

resource "aws_ecs_service" "techtest_app_frontend_service" {
  name            = "vibrato_techtest-ecs_service"
  cluster         = "${aws_ecs_cluster.cluster.id}"
  task_definition = "${aws_ecs_task_definition.ecs_task.arn}"
  desired_count   = 3
  depends_on = ["aws_alb_listener.load_balancer_listener"]

  ordered_placement_strategy {
    type  = "spread"
    field = "instanceId"
  }

  load_balancer {
    target_group_arn = "${aws_alb_target_group.load_balancer-target_group.arn}"
    container_name   = "techtest-frontend"
    container_port   = 3000 # todo parameterise this
  }
}