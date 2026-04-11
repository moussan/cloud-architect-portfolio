# ADR-003: Transit Gateway Over VPC Peering for Enterprise Networking

**Status:** Accepted  
**Date:** 2026-04-11  
**Author:** Moussa El Najmi  

---

## Context

AWS offers two primary mechanisms for VPC-to-VPC connectivity:

1. **VPC Peering** — direct, non-transitive, 1:1 connections between VPCs
2. **Transit Gateway (TGW)** — a regional router hub connecting many VPCs and on-prem

---

## Decision

Use **Transit Gateway** as the primary routing hub for all inter-VPC and on-premises connectivity.

---

## Rationale

| Factor | VPC Peering | Transit Gateway | Winner |
|--------|------------|----------------|--------|
| Scalability | O(n²) connections | O(n) — all connect to hub | TGW |
| Route management | Manual per-peer routes | Centralized route tables | TGW |
| Inspection | Traffic bypasses hub | Route via inspection VPC | TGW |
| Transitive routing | Not supported | Supported | TGW |
| Cross-account | Supported (complex) | Via RAM sharing | TGW |
| Cost | Per GB data transfer | Per attachment + per GB | Peering (small scale) |
| On-prem integration | VPN per VPC | One VPN/DX to TGW | TGW |

**When VPC Peering is still appropriate:**
- Two VPCs with high-bandwidth, low-latency requirements (TGW adds ~1ms latency)
- Simple two-account setups where TGW overhead isn't justified
- Cost-sensitive non-production environments

---

## Consequences

- All VPCs attach to a central TGW
- Separate TGW route tables enforce network domain isolation
- Centralized egress through inspection VPC
- All cross-VPC traffic can be inspected by AWS Network Firewall

---

## References

- [AWS TGW documentation](https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html)
- [AWS Networking Blog: Building a hub-and-spoke network](https://aws.amazon.com/blogs/networking-and-content-delivery/centralize-access-using-vpc-interface-endpoints/)
- [TGW pricing](https://aws.amazon.com/transit-gateway/pricing/)
