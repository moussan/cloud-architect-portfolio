###############################################################################
# Landing Zone — outputs.tf
# Exports all IDs needed by downstream modules (networking, compute, security).
# Downstream modules reference these via terraform_remote_state data source:
#
#   data "terraform_remote_state" "landing_zone" {
#     backend = "s3"
#     config  = { bucket = "...", key = "landing-zone/terraform.tfstate", region = "..." }
#   }
#
#   data.terraform_remote_state.landing_zone.outputs.shared_services_account_id
###############################################################################

###############################################################################
# Organisation
###############################################################################

output "org_id" {
  description = "The unique identifier of the AWS Organisation (e.g., o-xxxxxxxxxxxx). Required for organisation-level service delegations (GuardDuty, Security Hub)."
  value       = aws_organizations_organization.this.id
}

output "org_arn" {
  description = "The ARN of the AWS Organisation."
  value       = aws_organizations_organization.this.arn
}

output "org_root_id" {
  description = "The unique identifier of the Organisation root (e.g., r-xxxx). Required for attaching SCPs and tag policies at the root level."
  value       = aws_organizations_organization.this.roots[0].id
}

output "master_account_id" {
  description = "The account ID of the management (master) account."
  value       = aws_organizations_organization.this.master_account_id
}

###############################################################################
# Organisational Unit IDs
###############################################################################

output "security_ou_id" {
  description = "ID of the Security OU. Used when attaching security-specific SCPs or enrolling new security accounts."
  value       = aws_organizations_organizational_unit.security.id
}

output "security_ou_arn" {
  description = "ARN of the Security OU."
  value       = aws_organizations_organizational_unit.security.arn
}

output "infrastructure_ou_id" {
  description = "ID of the Infrastructure OU. Used when provisioning new shared services accounts."
  value       = aws_organizations_organizational_unit.infrastructure.id
}

output "infrastructure_ou_arn" {
  description = "ARN of the Infrastructure OU."
  value       = aws_organizations_organizational_unit.infrastructure.arn
}

output "workloads_ou_id" {
  description = "ID of the Workloads parent OU."
  value       = aws_organizations_organizational_unit.workloads.id
}

output "workloads_ou_arn" {
  description = "ARN of the Workloads parent OU."
  value       = aws_organizations_organizational_unit.workloads.arn
}

output "production_ou_id" {
  description = "ID of the Production OU. New production accounts should be placed here to inherit production SCPs."
  value       = aws_organizations_organizational_unit.production.id
}

output "production_ou_arn" {
  description = "ARN of the Production OU."
  value       = aws_organizations_organizational_unit.production.arn
}

output "non_prod_ou_id" {
  description = "ID of the Non-Production OU. Development and staging accounts live here."
  value       = aws_organizations_organizational_unit.non_prod.id
}

output "non_prod_ou_arn" {
  description = "ARN of the Non-Production OU."
  value       = aws_organizations_organizational_unit.non_prod.arn
}

output "sandbox_ou_id" {
  description = "ID of the Sandbox OU. Engineer exploration accounts live here."
  value       = aws_organizations_organizational_unit.sandbox.id
}

output "sandbox_ou_arn" {
  description = "ARN of the Sandbox OU."
  value       = aws_organizations_organizational_unit.sandbox.arn
}

###############################################################################
# Member Account IDs
###############################################################################

output "log_archive_account_id" {
  description = "Account ID of the Log Archive account. CloudTrail S3 buckets, VPC Flow Log buckets, and Config delivery channels all target this account."
  value       = aws_organizations_account.log_archive.id
}

output "security_tooling_account_id" {
  description = "Account ID of the Security Tooling account. GuardDuty delegated admin, Security Hub aggregator, Inspector, and Macie all run here."
  value       = aws_organizations_account.security_tooling.id
}

output "shared_services_account_id" {
  description = "Account ID of the Shared Services account. Transit Gateway, Route 53 Resolver, and shared VPCs are provisioned here."
  value       = aws_organizations_account.shared_services.id
}

output "prod_app1_account_id" {
  description = "Account ID of the first production application account."
  value       = aws_organizations_account.prod_app1.id
}

output "prod_app2_account_id" {
  description = "Account ID of the second production application account."
  value       = aws_organizations_account.prod_app2.id
}

output "dev_account_id" {
  description = "Account ID of the development account."
  value       = aws_organizations_account.dev.id
}

output "staging_account_id" {
  description = "Account ID of the staging account."
  value       = aws_organizations_account.staging.id
}

output "sandbox_account_id" {
  description = "Account ID of the sandbox account."
  value       = aws_organizations_account.sandbox.id
}

###############################################################################
# SCP IDs
###############################################################################

output "scp_deny_non_allowed_regions_id" {
  description = "Policy ID for DenyNonAllowedRegions SCP. Use to attach this SCP to additional OUs as the organisation grows."
  value       = aws_organizations_policy.deny_non_allowed_regions.id
}

output "scp_deny_leave_org_id" {
  description = "Policy ID for DenyLeaveOrganization SCP."
  value       = aws_organizations_policy.deny_leave_organization.id
}

output "scp_require_imdsv2_id" {
  description = "Policy ID for RequireIMDSv2 SCP."
  value       = aws_organizations_policy.require_imdsv2.id
}

output "scp_deny_root_account_actions_id" {
  description = "Policy ID for DenyRootAccountActions SCP."
  value       = aws_organizations_policy.deny_root_account_actions.id
}

output "scp_require_s3_sse_id" {
  description = "Policy ID for RequireS3SSE SCP."
  value       = aws_organizations_policy.require_s3_sse.id
}

output "scp_deny_public_s3_id" {
  description = "Policy ID for DenyPublicS3Buckets SCP."
  value       = aws_organizations_policy.deny_public_s3.id
}

output "tag_policy_id" {
  description = "Policy ID for the OrganisationTagPolicy tag policy."
  value       = aws_organizations_policy.tag_policy.id
}

###############################################################################
# Convenience Map Outputs
###############################################################################

output "all_ou_ids" {
  description = "Map of all OU names to their IDs. Useful for dynamic lookups in downstream modules."
  value = {
    security       = aws_organizations_organizational_unit.security.id
    infrastructure = aws_organizations_organizational_unit.infrastructure.id
    workloads      = aws_organizations_organizational_unit.workloads.id
    production     = aws_organizations_organizational_unit.production.id
    non_prod       = aws_organizations_organizational_unit.non_prod.id
    sandbox        = aws_organizations_organizational_unit.sandbox.id
  }
}

output "all_account_ids" {
  description = "Map of all member account names to their IDs. Useful for generating provider aliases in multi-account Terraform configurations."
  value = {
    log_archive      = aws_organizations_account.log_archive.id
    security_tooling = aws_organizations_account.security_tooling.id
    shared_services  = aws_organizations_account.shared_services.id
    prod_app1        = aws_organizations_account.prod_app1.id
    prod_app2        = aws_organizations_account.prod_app2.id
    dev              = aws_organizations_account.dev.id
    staging          = aws_organizations_account.staging.id
    sandbox          = aws_organizations_account.sandbox.id
  }
}

output "all_scp_ids" {
  description = "Map of all SCP names to their policy IDs."
  value = {
    deny_non_allowed_regions  = aws_organizations_policy.deny_non_allowed_regions.id
    deny_leave_organization   = aws_organizations_policy.deny_leave_organization.id
    require_imdsv2            = aws_organizations_policy.require_imdsv2.id
    deny_root_account_actions = aws_organizations_policy.deny_root_account_actions.id
    require_s3_sse            = aws_organizations_policy.require_s3_sse.id
    deny_public_s3            = aws_organizations_policy.deny_public_s3.id
  }
}
