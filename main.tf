terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# --- Finding candidate 1: security group open to the world on SSH ---
resource "aws_security_group" "web" {
  name        = "web-sg"
  description = "Web server security group"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # world-open SSH
  }

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # world-open, all ports
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Finding candidate 2: S3 bucket with no encryption, no versioning, public ACL ---
resource "aws_s3_bucket" "data" {
  bucket = "deepsource-demo-data-bucket"
}

resource "aws_s3_bucket_acl" "data_acl" {
  bucket = aws_s3_bucket.data.id
  acl    = "public-read" # publicly readable bucket
}

# --- Finding candidate 3: overly permissive IAM policy (Action:* Resource:*) ---
resource "aws_iam_policy" "admin_everything" {
  name = "admin-everything"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      }
    ]
  })
}

# --- Finding candidate 4: unencrypted, publicly accessible RDS instance ---
resource "aws_db_instance" "primary" {
  identifier          = "deepsource-demo-db"
  engine              = "mysql"
  instance_class      = "db.t3.micro"
  allocated_storage   = 20
  username            = "admin"
  password            = "ChangeMe123!" # hardcoded credential
  publicly_accessible = true
  storage_encrypted   = false
  skip_final_snapshot = true
}

# --- Finding candidate 5: unused variable / dead code for lint noise ---
variable "unused_tag" {
  type    = string
  default = "unused"
}
