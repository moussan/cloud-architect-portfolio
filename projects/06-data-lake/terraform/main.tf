terraform {
  backend "s3" {
    bucket         = "moussa-cloud-portfolio-tf-state"
    key            = "projects/06-data-lake/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "moussa-cloud-portfolio-tf-locks"
  }

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

resource "aws_kms_key" "datalake" {
  description             = "KMS key for encrypting Data Lake S3 buckets and Athena"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "datalake" {
  name          = "alias/${var.project_name}-kms"
  target_key_id = aws_kms_key.datalake.key_id
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

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_encryption" {
  bucket = aws_s3_bucket.raw.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.datalake.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed_encryption" {
  bucket = aws_s3_bucket.processed.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.datalake.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_glue_catalog_database" "this" {
  name = "${var.project_name}_db"
}

resource "aws_glue_crawler" "raw_crawler" {
  name          = "${var.project_name}-raw-crawler"
  role          = var.glue_role_arn
  database_name = aws_glue_catalog_database.this.name

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
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.datalake.arn
      }
    }
  }
}
