output "ingest_bucket" {
  value = aws_s3_bucket.ingest.bucket
}

output "dynamodb_table" {
  value = aws_dynamodb_table.events.name
}

output "sns_topic_arn" {
  value = aws_sns_topic.notifications.arn
}
