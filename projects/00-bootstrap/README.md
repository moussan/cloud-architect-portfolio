# Bootstrap Remote State

This project provisions the foundational resources required for managing the Terraform state of the rest of the portfolio projects.

It creates:
- An Amazon S3 bucket to store the `.tfstate` files remotely, providing versioning and encryption by default.
- An Amazon DynamoDB table to handle state locking and consistency checking.

## Usage
Since this project manages the remote state backend, it initially uses local state to bootstrap itself.

```bash
cd terraform
terraform init
terraform plan
terraform apply
```
