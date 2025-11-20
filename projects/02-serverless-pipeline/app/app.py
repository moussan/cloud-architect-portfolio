import json
import os
import uuid
from datetime import datetime, timezone

import boto3

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")

TABLE_NAME = os.environ["TABLE_NAME"]
TOPIC_ARN = os.environ["TOPIC_ARN"]
PROJECT_ENV = os.environ.get("PROJECT_ENV", "dev")

table = dynamodb.Table(TABLE_NAME)


def parse_s3_record(record):
  s3 = record.get("s3", {})
  bucket = s3.get("bucket", {}).get("name")
  obj = s3.get("object", {})
  key = obj.get("key")
  size = obj.get("size", 0)
  event_time = record.get("eventTime") or datetime.now(timezone.utc).isoformat()
  return bucket, key, size, event_time


def lambda_handler(event, context):
  print("Received event:", json.dumps(event))

  records = event.get("Records", [])
  processed = []

  for record in records:
    if record.get("eventSource") != "aws:s3":
      continue

    bucket, key, size, event_time = parse_s3_record(record)
    if not bucket or not key:
      continue

    item_id = str(uuid.uuid4())
    item = {
      "id": item_id,
      "bucket": bucket,
      "object_key": key,
      "size": size,
      "event_time": event_time,
      "created_at": datetime.now(timezone.utc).isoformat(),
      "env": PROJECT_ENV,
    }

    table.put_item(Item=item)
    processed.append(item)

    sns.publish(
      TopicArn=TOPIC_ARN,
      Subject=f"[{PROJECT_ENV}] New object: {key}"[:100],
      Message=json.dumps(item, indent=2),
    )

  return {
    "statusCode": 200,
    "body": json.dumps(
      {"message": "Processed S3 events", "processed_count": len(processed)}
    ),
  }
