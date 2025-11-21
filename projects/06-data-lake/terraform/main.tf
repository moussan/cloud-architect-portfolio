terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

resource "aws_s3_bucket" "raw" {
  bucket = "${var.project_name}-raw-${random_id.suffix.hex}"

  force_destroy = true

  tags = {
    Name = "${var.project_name}-raw"
    Zone = "raw"
  }
}

resource "aws_s3_bucket" "processed" {
  bucket = "${var.project_name}-processed-${random_id.suffix.hex}"

  force_destroy = true

  tags = {
    Name = "${var.project_name}-processed"
    Zone = "processed"
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_glue_database" "this" {
  name = "${var.project_name}_db"
}

resource "aws_glue_crawler" "raw_crawler" {
  name          = "${var.project_name}-raw-crawler"
  role          = var.glue_role_arn
  database_name = aws_glue_database.this.name

  s3_target {
    path = "s3://${aws_s3_bucket.raw.bucket}/"
  }

  schedule = "cron(0 0 * * ? *)" # daily

  configuration = jsonencode({
    Version = 1.0
  })
}

resource "aws_athena_workgroup" "this" {
  name = "${var.project_name}-wg"

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.processed.bucket}/athena-results/"
    }
  }
}
