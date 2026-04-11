# Database Architecture

> **Reference implementation:** Aurora Serverless v2 (MySQL 8.0) with RDS Proxy, Secrets Manager rotation, and Performance Insights.

---

## Table of Contents

1. [RDS vs Aurora](#rds-vs-aurora)
2. [Multi-AZ vs Read Replicas](#multi-az-vs-read-replicas)
3. [DynamoDB](#dynamodb)
4. [ElastiCache](#elasticache)
5. [Encryption At Rest and In Transit](#encryption-at-rest-and-in-transit)
6. [Parameter Groups and Option Groups](#parameter-groups-and-option-groups)
7. [Backup Strategy](#backup-strategy)
8. [RDS Proxy](#rds-proxy)
9. [FAQ](#-faq)
10. [AWS Documentation Links](#aws-documentation-links)

---

## RDS vs Aurora

### RDS

Standard managed MySQL/PostgreSQL/SQL Server/Oracle running on dedicated EC2 instances. You choose the instance type; you pay whether you use it or not.

**Choose RDS when:**
- You need database engines Aurora doesn't support (Oracle, SQL Server, Db2)
- Your workload is stable and predictable — always-on capacity is cost-effective
- You need `db.m6g.large` or smaller — Aurora has minimum ACU requirements
- Specific parameter parity is required (Aurora doesn't support all MySQL/PostgreSQL parameters)

### Aurora (MySQL-compatible and PostgreSQL-compatible)

Aurora is a purpose-built cloud database, not a managed version of MySQL/PostgreSQL. It separates compute from storage:

- **Storage**: Distributed across 6 copies in 3 AZs — automatically, without you configuring it
- **Compute**: Aurora instances (writer + readers) that connect to the shared storage volume
- **Redo log** writes go directly to the storage layer — no buffer pool flushing on write-ahead logs

**Aurora performance advantages over RDS:**
- 5x throughput of MySQL, 3x throughput of PostgreSQL (in AWS benchmarks)
- Failover < 30 seconds (vs 60-120 seconds for RDS Multi-AZ)
- Read replicas share the same storage — no replication lag for most reads
- Aurora Global Database spans multiple regions with < 1 second replication lag

### Aurora Serverless v2

Aurora Serverless v2 scales the Aurora compute tier automatically:

```
Min: 0.5 ACUs (Aurora Capacity Units)
Max: 128 ACUs

1 ACU ≈ 2 GB RAM + proportional CPU + networking
```

**When Aurora Serverless v2 makes sense:**

| Scenario | Recommended |
|---|---|
| Unpredictable or spiky traffic | ✅ Yes — scales to 0.5 ACU in minutes |
| Dev/test environments | ✅ Yes — scales down when idle |
| SaaS multi-tenant (variable per-tenant load) | ✅ Yes |
| Stable, high-throughput production workload | ❌ No — provisioned instances have lower latency |
| < 2 ACU average utilization | ✅ Yes — cheaper than smallest provisioned instance |

> **Why Serverless v2 instead of v1?**  
> Serverless v1 scaled in coarse steps (minimum 1 ACU, scaled to multiples of 1 ACU) and could take 15-30 seconds to scale. v2 scales in fine-grained 0.5-ACU increments in under a second. v1 also couldn't serve as a Global Database writer. v1 is effectively superseded.

---

## Multi-AZ vs Read Replicas

These solve **different problems**. Confusing them is one of the most common database architecture mistakes.

### Multi-AZ — High Availability

Multi-AZ maintains a synchronous standby in a different AZ. It is **purely for availability**, not performance.

```
Primary (us-east-1a) ←——synchronous replication——→ Standby (us-east-1b)
      ↕                                                   ↕
 Writes go here                                    Takes over if primary fails
 Reads go here                                     NOT used for reads normally
```

- **Failover time**: < 30 seconds (Aurora), 60-120 seconds (RDS)
- **Standby is invisible** to applications — they always connect to the primary endpoint
- **Does not improve read throughput** — standby handles no read traffic

### Read Replicas — Read Scalability

Read replicas use **asynchronous** replication. They are for distributing read traffic, not for failover (though they can be promoted manually).

```
Primary ——async replication——→ Read Replica 1 (same or different AZ)
                              → Read Replica 2 (different region)
```

- **Replication lag**: milliseconds to seconds (application must handle stale reads)
- **Application change required**: direct read queries to the reader endpoint
- **Aurora advantage**: replicas share the same storage volume — effectively zero replication lag

> **Rule: Use Multi-AZ for HA, Read Replicas for scale. They are not substitutes for each other.**

For Aurora specifically: the cluster automatically uses Multi-AZ storage (6 copies, 3 AZs). You add Aurora Replicas for read scalability. If the writer fails, Aurora promotes a reader in < 30 seconds — this is both HA and read scalability in one.

---

## DynamoDB

### Partition Key Design

The partition key is the most important design decision in DynamoDB. Poor partition key design leads to "hot partitions" that throttle and degrade performance.

**Good partition keys:**
- **High cardinality** — many unique values spread load evenly
- **Unpredictable** — access patterns don't concentrate on a few values
- Examples: user_id (UUID), order_id (UUID), device_id

**Bad partition keys:**
- Date-only (e.g., `2024-01-15`) — all today's writes go to one partition
- Boolean status (e.g., `active/inactive`) — only 2 partitions
- Country code — popular countries (US) become hot partitions

**Composite key strategy**: Use `PK` (partition) + `SK` (sort key) with a hierarchical sort key pattern:

```
PK = "USER#user-uuid-123"
SK = "ORDER#2024-01-15T10:30:00Z#order-uuid-456"
```

This lets you query all orders for a user with a `begins_with` condition on the sort key.

### Global Secondary Indexes (GSIs)

GSIs let you query by attributes other than the primary key. Each GSI is a separate distributed data structure with its own throughput:

```hcl
global_secondary_index {
  name            = "email-index"
  hash_key        = "email"
  projection_type = "ALL"
  # WHY ALL projection? Avoids fetching the base table for every GSI query.
  # If the item is large and only some attributes are needed, use INCLUDE.
}
```

> **GSI hot key warning:** GSIs have the same hot partition problem as base tables. If you create a GSI on `status` with only 3 values (active/inactive/deleted), your GSI will have hot partitions. Add a random suffix shard: `status#1`, `status#2` ... `status#N`, then query all shards in parallel.

### DAX (DynamoDB Accelerator)

DAX is an in-memory write-through cache for DynamoDB — microsecond latency for cached reads. Use it when:
- P99 read latency from DynamoDB is too high (>1ms)
- The same items are read repeatedly (high cache hit ratio expected)
- You cannot change application code significantly (DAX is API-compatible with DynamoDB)

Do not use DAX when: strongly consistent reads are required (DAX serves eventually consistent reads only), or when your access pattern has no repetition (cache hit rate near 0%).

### On-Demand vs Provisioned

| | On-Demand | Provisioned |
|---|---|---|
| **When to use** | Unpredictable traffic, new tables | Predictable workloads, cost optimization |
| **Pricing** | Pay per request | Pay for provisioned RCU/WCU |
| **Scaling** | Instant | Requires Application Auto Scaling or manual |
| **Cost at high load** | More expensive | More predictable (cheaper at scale) |

Rule: Start with On-Demand. Move to Provisioned with Auto Scaling once you have 2 weeks of traffic data to base capacity on.

---

## ElastiCache

### Redis vs Memcached

| | Redis | Memcached |
|---|---|---|
| **Data structures** | Strings, hashes, lists, sets, sorted sets, streams, HLL | Strings only |
| **Persistence** | Yes (AOF + RDB snapshots) | No |
| **Replication** | Yes (primary + replicas, Multi-AZ) | No |
| **Cluster mode** | Yes — horizontal sharding | Yes — but simpler |
| **Pub/Sub** | Yes | No |
| **Lua scripting** | Yes | No |
| **Session storage** | ✅ Ideal (persistent, replicable) | ⚠️ Data loss on node failure |
| **Leaderboards / rate limiting** | ✅ Sorted sets | ❌ No |
| **Simple object cache** | ✅ | ✅ Simpler, marginally faster per-node |

> **Rule: Use Redis for almost everything.** Choose Memcached only when you need multi-threaded performance and horizontal scaling of a pure cache with no persistence requirements, and you have Memcached operational expertise in your team.

### ElastiCache Serverless (Redis, 2023)

ElastiCache Serverless automatically scales Redis capacity up and down. Appropriate for:
- Variable workloads where provisioning capacity is difficult
- Dev/test environments
- Applications where a fully managed cache with minimal ops is preferred over maximum cost optimization

---

## Encryption At Rest and In Transit

### At Rest

| Service | Mechanism | Enable With |
|---|---|---|
| RDS / Aurora | KMS CMK | `storage_encrypted = true` + `kms_key_id` |
| DynamoDB | AWS-managed key (default) or CMK | `server_side_encryption { enabled = true }` |
| ElastiCache Redis | KMS CMK | `at_rest_encryption_enabled = true` |

All three services support CMKs. Use a CMK (not AWS-managed key) for production when you need: custom key policy, CloudTrail audit trail, or cross-account access.

### In Transit

| Service | Mechanism | Enable With |
|---|---|---|
| RDS / Aurora | TLS required via parameter group | `rds.force_ssl = 1` (MySQL), `ssl_min_protocol_version` (PostgreSQL) |
| DynamoDB | TLS always — no configuration needed | N/A |
| ElastiCache Redis | TLS | `transit_encryption_enabled = true` |

For Aurora MySQL, enforce SSL in the parameter group: `require_secure_transport = ON`. Application connection strings should include `ssl-mode=VERIFY_IDENTITY` or equivalent.

---

## Parameter Groups and Option Groups

### Parameter Groups

Parameter groups configure database engine settings. Key production settings for MySQL/Aurora:

```hcl
parameter {
  name  = "slow_query_log"
  value = "1"
  # Logs queries exceeding long_query_time. Essential for performance tuning.
}

parameter {
  name  = "long_query_time"
  value = "2"
  # Queries taking > 2 seconds are slow queries. Adjust based on your SLAs.
}

parameter {
  name  = "max_connections"
  value = "1000"
  # Aurora Serverless: max_connections = 1000 * ACU count roughly.
  # Use RDS Proxy to handle connection pooling instead of increasing this.
}

parameter {
  name  = "require_secure_transport"
  value = "ON"
  # Enforce TLS for all connections. Clients without TLS are rejected.
}

parameter {
  name  = "general_log"
  value = "0"
  # Keep disabled in production — general log logs every statement,
  # creating massive I/O overhead and storage growth.
  # Enable briefly for debugging specific issues only.
}
```

Parameter changes are either **static** (require reboot) or **dynamic** (applied immediately). Check the [AWS parameter documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Reference.ParameterGroups.html) before modifying a parameter in production.

### Option Groups

Option groups add features to the database engine (MySQL/Oracle/SQL Server). Examples:
- `MARIADB_AUDIT_PLUGIN` — audit logging for MySQL/MariaDB
- `OEM` — Oracle Enterprise Manager for Oracle
- `MEMCACHED` — Memcached plugin for MySQL (rarely used)

Aurora uses a parameter group family per engine version. Aurora MySQL 8.0 uses `aurora-mysql8.0`.

---

## Backup Strategy

### Automated Backups (Aurora/RDS)

- Stored in S3 (AWS-managed, not visible in your account)
- Continuous — Aurora backs up continuously to S3 (not snapshot-based like RDS)
- Retention: 1-35 days (use 7+ days for production)
- Point-in-time recovery: restore to any second within the retention window
- **Cost**: included in Aurora pricing — no additional cost for automated backups

### Manual Snapshots

- Persist beyond the retention window (until explicitly deleted)
- Taken before major changes (engine upgrade, schema migration)
- Cross-region copy: `aws rds copy-db-cluster-snapshot --destination-region us-west-2`
- Cross-account share: `aws rds modify-db-cluster-snapshot-attribute --values-to-add <account-id>`

### AWS Backup (Centralized)

For multi-account environments, use AWS Backup to enforce backup policies via Organizations:

```hcl
resource "aws_backup_plan" "databases" {
  name = "production-databases"

  rule {
    rule_name         = "daily-30-day-retention"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 3 * * ? *)"   # 3 AM UTC daily

    lifecycle {
      delete_after = 30
    }

    copy_action {
      destination_vault_arn = var.dr_vault_arn   # Cross-region vault for DR
      lifecycle {
        delete_after = 7   # Keep cross-region backup for 7 days only
      }
    }
  }
}
```

---

## RDS Proxy

RDS Proxy sits between your application and the database, pooling and reusing connections. This is critical for Lambda functions, containerized microservices, and any workload with many short-lived database connections.

**The problem:** MySQL/PostgreSQL connection creation is expensive (5-30ms). Lambda functions create a new connection on every cold start. 1,000 concurrent Lambda invocations = 1,000 database connections. `max_connections` on a `db.r6g.large` MySQL instance is ~640. Lambda will exhaust it.

**RDS Proxy solves this:**
```
1,000 Lambda connections → RDS Proxy (pools) → 50 real DB connections
```

**Additional benefits:**
- **Seamless failover**: Proxy maintains connections through Aurora failovers — application sees no interruption
- **IAM authentication**: Applications authenticate to the proxy with IAM; the proxy uses a Secrets Manager credential for the DB
- **Connection pinning avoidance**: Be aware that operations requiring session-level state (temporary tables, `SET` commands, transactions) cause the proxy to "pin" a connection, bypassing pooling

---

## ❓ FAQ

**Q: When should I use Aurora Serverless v2 vs provisioned Aurora?**

A: Serverless v2 is cheaper when your average utilization is below the cost break-even of the smallest provisioned instance (`db.r6g.large` ≈ 8 ACU equivalent). If you're running 24/7 at 8+ ACUs, a provisioned `db.r6g.large` is cheaper per ACU-hour. Use Serverless v2 for: dev/test, bursty SaaS workloads, new applications where capacity is unknown, and any workload where idle time during off-hours is significant.

---

**Q: What is the maximum Aurora Serverless v2 scale-up speed?**

A: Aurora Serverless v2 can double its capacity every ~30 seconds. From 0.5 ACU to 128 ACU takes approximately 4 doublings, or about 2 minutes under sustained max load. For sudden large traffic spikes, pre-warming the cluster or using provisioned instances for the writer is safer. Set `max_capacity` based on your realistic peak, not theoretical max — at 128 ACU, you're paying ~$7/hour for compute alone.

---

**Q: How do I migrate from RDS MySQL to Aurora MySQL?**

A: Two paths:
1. **Snapshot restore**: Take a final RDS snapshot → restore as Aurora cluster. This requires a maintenance window and has a cutover period of ~30-60 minutes for large databases.
2. **DMS (Database Migration Service)**: Set up DMS for continuous replication from RDS to Aurora with minimal downtime. Cutover when replication lag is near zero. This adds DMS complexity but reduces downtime to seconds.

For most migrations, snapshot restore is the simpler and cheaper path. Reserve DMS for databases where any downtime is unacceptable.

---

**Q: How do I handle database schema migrations with IaC?**

A: Database schema is application-layer concerns — do not manage it in Terraform. Terraform provisions the database infrastructure (cluster, security groups, parameter groups). Schema migrations should be managed by your application's migration tool (Flyway, Liquibase, Django migrations, Alembic) as part of the CI/CD pipeline, not as Terraform resources. The deployment sequence is:

1. Terraform apply → database infrastructure exists
2. App deployment pipeline → runs `flyway migrate` (or equivalent) before starting new app instances
3. App instances start → use the current schema

---

**Q: What is the performance difference between `io1` and `io2` storage for RDS?**

A: For RDS (not Aurora), both `io1` and `io2` offer up to 64,000 IOPS, but `io2` has better durability (99.999% vs 99.8%), 256,000 IOPS on `io2 Block Express` (for `db.r6i` and larger), and 4x the throughput. `io2` is the same price as `io1`. There is no reason to use `io1` for new workloads. Note: Aurora does not use EBS storage — this comparison applies only to RDS.

---

**Q: When should I use DynamoDB Streams?**

A: DynamoDB Streams captures a time-ordered sequence of every item modification as a stream of events. Use cases:
- **Event-driven architectures**: trigger Lambda on every DynamoDB write
- **Cross-region replication**: DynamoDB Global Tables uses Streams internally
- **Audit logs**: capture every change to a table item
- **ElastiCache invalidation**: invalidate cache entries when DynamoDB records change

Each Streams shard has a 24-hour retention period. If your consumer falls behind by more than 24 hours, events are lost — monitor `IteratorAgeMilliseconds` metric.

---

**Q: How do I enforce column-level encryption in Aurora MySQL?**

A: Aurora MySQL does not support native column-level encryption (unlike PostgreSQL's `pgcrypto`). Options:
1. **Application-level encryption**: Encrypt sensitive fields (SSN, PAN, DOB) in application code before writing to the database using a KMS data key. The database stores ciphertext. Searching on encrypted columns requires tokenization or format-preserving encryption (AWS Encryption SDK supports this).
2. **AWS CloudHSM with MySQL Keyring plugin**: For FIPS 140-2 Level 3 requirements.
3. **Amazon RDS for Oracle/SQL Server**: Have native Transparent Data Encryption (TDE) at the column level.

Column-level encryption adds significant application complexity. Evaluate whether row-level (IAM + VPC), table-level, or database-level encryption meets your requirements first.

---

**Q: What is the difference between RDS Proxy and PgBouncer / ProxySQL?**

A: RDS Proxy is a fully managed service with IAM authentication, Secrets Manager integration, automatic failover handling, and no infrastructure to maintain. PgBouncer/ProxySQL are self-managed proxies that you run on EC2 or containers — they give more configuration flexibility and potentially lower overhead for experienced DBAs, but require patching, monitoring, and HA configuration. Use RDS Proxy for: Lambda-to-RDS, containerized microservices, and any team that doesn't have deep proxy expertise. Use self-managed proxies only if RDS Proxy connection limits or feature set are insufficient.

---

**Q: How do I calculate the right `max_connections` value?**

A: For MySQL/Aurora MySQL, the formula is roughly:

```
max_connections = min(DBInstanceClassMemory / 12582880, 1000)
```

For Aurora Serverless v2 at a given ACU, AWS publishes the memory per ACU (2 GB/ACU). The default `max_connections` formula for Aurora MySQL 8.0 is:

```
max_connections = LEAST({DBInstanceClassMemory/12582880}, 3000)
```

At 1 ACU (2 GB RAM): `2 * 1024^3 / 12582880 ≈ 171 connections`.

> **This is why RDS Proxy is essential for Lambda and containers** — 171 connections disappear instantly when 200 Lambda invocations cold-start simultaneously.

---

## AWS Documentation Links

- [Amazon Aurora Overview](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/CHAP_AuroraOverview.html)
- [Aurora Serverless v2](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.html)
- [RDS Multi-AZ](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.html)
- [Aurora Read Replicas](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Replication.html)
- [RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html)
- [DynamoDB Best Practices](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/best-practices.html)
- [DynamoDB Partition Key Design](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-partition-key-design.html)
- [ElastiCache for Redis](https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/WhatIs.html)
- [Aurora Parameter Groups](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Reference.ParameterGroups.html)
- [RDS Encryption](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Overview.Encryption.html)
- [AWS Backup for RDS](https://docs.aws.amazon.com/aws-backup/latest/devguide/assigning-resources.html)
