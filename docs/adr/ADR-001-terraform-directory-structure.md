# ADR-001: Terraform Directory Structure — Directories Over Workspaces

**Status:** Accepted  
**Date:** 2026-04-11  
**Author:** Moussa El Najmi  

---

## Context

When managing multiple environments (dev, staging, prod) with Terraform, two patterns exist:

1. **Terraform Workspaces** — one directory, multiple `terraform.workspace` references
2. **Directory-per-environment** — separate `envs/dev/`, `envs/staging/`, `envs/prod/` directories

---

## Decision

We use **directory-based environment isolation**, not Terraform workspaces.

---

## Rationale

| Factor | Workspaces | Directories | Winner |
|--------|-----------|-------------|--------|
| State isolation | Shared backend, separate keys | Fully separate state files | Directories |
| Blast radius | Accidental `terraform apply` in wrong workspace | Apply only affects target dir | Directories |
| CI/CD clarity | Must set workspace before every command | `cd envs/prod && terraform apply` | Directories |
| Variable management | Single tfvars with conditionals | Separate tfvars per env | Directories |
| Code review | Hard to diff workspace-specific changes | Clear per-environment PR scope | Directories |
| Drift detection | Complex | Simple | Directories |

Workspaces are fine for short-lived ephemeral environments (feature branches, PR previews). They are **not appropriate** for permanent environment promotion pipelines.

---

## Consequences

- Each pillar has its own `terraform/` directory
- State files are isolated per module
- `terraform plan` must be run from the correct directory
- Environment promotion is done via `tfvars` file differences, not workspace switching

---

## References

- [Terraform docs: When to use workspaces](https://developer.hashicorp.com/terraform/language/state/workspaces#when-to-use-multiple-workspaces)
- [Gruntwork: Terraform best practices](https://www.gruntwork.io/guides/foundations/how-to-use-terraform-at-scale/)
