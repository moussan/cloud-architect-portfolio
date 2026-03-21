.PHONY: help bootstrap deploy-ha-web-app destroy-ha-web-app

help:
	@echo "Available commands:"
	@echo "  make bootstrap            - Deploy the 00-bootstrap remote state backend"
	@echo "  make deploy-ha-web-app    - Deploy the 01-ha-web-app project"
	@echo "  make destroy-ha-web-app   - Destroy the 01-ha-web-app project"
	@echo "  make deploy-all           - Deploy all projects sequentially"

bootstrap:
	cd projects/00-bootstrap/terraform && terraform init -upgrade && terraform apply -auto-approve

deploy-ha-web-app:
	cd projects/01-ha-web-app/terraform && terraform init -upgrade && terraform apply -auto-approve

destroy-ha-web-app:
	cd projects/01-ha-web-app/terraform && terraform destroy -auto-approve

deploy-all: bootstrap deploy-ha-web-app
	@echo "All configured projects deployed successfully."
