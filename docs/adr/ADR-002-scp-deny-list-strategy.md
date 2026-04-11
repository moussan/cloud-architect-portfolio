# ADR-002: SCP Strategy — Deny-List Over Allow-List

**Status:** Accepted  
**Date:** 2026-04-11  
**Author:** Moussa El Najmi  

---

## Context

SCPs can be implemented in two modes:

1. **Allow-list**: Remove the default `FullAWSAccess` SCP and explicitly permit only specific actions
2. **Deny-list**: Keep `FullAWSAccess` and layer explicit `Deny` statements on top

---

## Decision

We use the **deny-list approach** with targeted explicit denies.

---

## Rationale

| Factor | Allow-list | Deny-list | Winner |
|--------|-----------|-----------|--------|
| Operational overhead | Very high — must allow every service used | Low — only deny what's prohibited | Deny-list |
| Risk of breaking things | High — missing an allow breaks workloads | Low — explicit denies are additive | Deny-list |
| Auditability | Hard to reason about what's permitted | Easy to see what's restricted | Deny-list |
| New AWS services | Must update allow-list for every new service | New services work by default | Deny-list |
| Exceptions handling | Complex nested conditions | Condition-based IAM principal exclusions | Tie |

Allow-list is appropriate only when the organization has extreme compliance requirements (e.g., FedRAMP HIGH, classified government) where the principle is "deny everything not explicitly permitted."

For commercial enterprises, deny-list gives the right balance of security and agility.

---

## Exception Pattern

When a specific role must bypass an SCP deny (e.g., break-glass admin):

```json
{
  "Effect": "Deny",
  "Action": "...",
  "Resource": "*",
  "Condition": {
    "StringNotEquals": {
      "aws:PrincipalARN": [
        "arn:aws:iam::*:role/BreakGlassAdminRole"
      ]
    }
  }
}
```

---

## References

- [AWS SCP documentation](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
- [AWS Security Blog: SCP best practices](https://aws.amazon.com/blogs/security/how-to-use-service-control-policies-to-set-permission-guardrails-across-accounts-in-your-aws-organization/)
