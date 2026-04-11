# Cloud Architect Portfolio — Makefile
# Moussa El Najmi | Senior AWS Solutions Architect
#
# Usage: make <target> [MODULE=path/to/module]
# Example: make plan MODULE=01-governance/landing-zone/terraform

SHELL := /bin/bash
.PHONY: help init validate fmt plan apply destroy lint security-scan docs clean

MODULE ?= 03-iac/state-backend/terraform

help:  ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

init: ## terraform init in MODULE
	cd $(MODULE) && terraform init

validate: ## terraform validate in MODULE
	cd $(MODULE) && terraform validate

fmt: ## terraform fmt (recursive from repo root)
	terraform fmt -recursive .

fmt-check: ## Check formatting without writing
	terraform fmt -check -recursive .

plan: ## terraform plan in MODULE
	cd $(MODULE) && terraform plan -out=tfplan

apply: ## terraform apply (requires prior plan)
	cd $(MODULE) && terraform apply tfplan

destroy: ## terraform destroy in MODULE (CAREFUL)
	@echo "⚠️  This will destroy infrastructure in $(MODULE)"
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] && \
		cd $(MODULE) && terraform destroy || echo "Aborted."

lint: ## Run tflint on all modules
	@which tflint >/dev/null || (echo "Install tflint: https://github.com/terraform-linters/tflint" && exit 1)
	find . -name "*.tf" -not -path "*/.terraform/*" -exec dirname {} \; | sort -u | \
		xargs -I{} sh -c 'cd {} && tflint --init && tflint'

security-scan: ## Run tfsec on all Terraform code
	@which tfsec >/dev/null || (echo "Install tfsec: brew install tfsec" && exit 1)
	tfsec . --exclude-downloaded-modules

checkov: ## Run checkov policy scan
	@which checkov >/dev/null || (echo "Install checkov: pip install checkov" && exit 1)
	checkov -d . --framework terraform

docs: ## Generate terraform-docs for MODULE
	@which terraform-docs >/dev/null || (echo "Install terraform-docs: brew install terraform-docs" && exit 1)
	terraform-docs markdown table $(MODULE) > $(MODULE)/TERRAFORM_DOCS.md
	@echo "Docs written to $(MODULE)/TERRAFORM_DOCS.md"

docs-all: ## Generate terraform-docs for all modules
	@for dir in \
		01-governance/landing-zone/terraform \
		01-governance/iam/terraform \
		01-governance/scps/terraform \
		02-networking/hub-spoke/terraform \
		02-networking/vpc-design/terraform \
		03-iac/state-backend/terraform \
		03-iac/compute/terraform \
		03-iac/storage/terraform \
		03-iac/database/terraform \
		03-iac/modules/vpc \
		03-iac/modules/iam-role; do \
		echo "Generating docs for $$dir"; \
		terraform-docs markdown table $$dir > $$dir/TERRAFORM_DOCS.md; \
	done

validate-all: ## Validate all Terraform modules
	@failed=0; \
	for dir in \
		01-governance/landing-zone/terraform \
		01-governance/iam/terraform \
		01-governance/scps/terraform \
		02-networking/hub-spoke/terraform \
		02-networking/vpc-design/terraform \
		03-iac/state-backend/terraform \
		03-iac/compute/terraform \
		03-iac/storage/terraform \
		03-iac/database/terraform \
		03-iac/modules/vpc \
		03-iac/modules/iam-role; do \
		echo "Validating $$dir..."; \
		(cd $$dir && terraform init -backend=false -upgrade -no-color >/dev/null 2>&1 && terraform validate -no-color) || failed=1; \
	done; \
	[ $$failed -eq 0 ] && echo "✅ All modules validated" || echo "❌ Some modules failed validation"; \
	exit $$failed

clean: ## Remove .terraform directories and plan files
	find . -name ".terraform" -type d -exec rm -rf {} + 2>/dev/null; \
	find . -name "tfplan" -delete 2>/dev/null; \
	find . -name ".terraform.lock.hcl" -delete 2>/dev/null; \
	echo "Cleaned up Terraform artifacts"

cost: ## Run infracost estimate for MODULE
	@which infracost >/dev/null || (echo "Install infracost: https://www.infracost.io/docs/" && exit 1)
	infracost breakdown --path $(MODULE)
