provider "aws" {}

# Data block for current region
data "aws_region" "current" {}

# Data block for retrieving list of availability zones dynamically
data "aws_availability_zones" "available" {}

# Define a block of IPs sufficiently large for the purpose of this project
# /21 will give us 2048 IPs which we can divide into 3 private / 3 public subnets (one for each per AZ) 
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

resource "aws_vpc" "main" {
  cidr_block = "${var.cidr_block}"
}

# Create a group of public subnets; one for each AZ within the region we launched our VPC
resource "aws_subnet" "public" {
  count      = "${length(var.public_subnets)}"
  vpc_id     = "${aws_vpc.main.id}"
  cidr_block = "${var.public_subnets[count.index]}"
  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
}

# Create a group of private subnets; one for each AZ within the region we launched our VPC
resource "aws_subnet" "private" {
  count      = "${length(var.private_subnets)}"
  vpc_id     = "${aws_vpc.main.id}"
  cidr_block = "${var.private_subnets[count.index]}"
  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
}