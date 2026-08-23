# Receivables Hub — Architecture One-Pager

Companion to [MODERNIZATION_PLAN.md](./MODERNIZATION_PLAN.md).

## Problem

Three receivable cores (mainframe nightly VSAM/COBOL, event-capable modern core, ETL/lakehouse core) feed experiences today via legacy DB2-centric processes. Models differ (account-based vs customer-based). UX needs a single, trusted store with batch + near-real-time freshness under PCI/SOX/PII constraints.

## Solution

GCP **Receivables Hub**: land all sources → normalize → **canonical PostgreSQL** → domain APIs → BFFs → simple self-serve/agent web apps. DB2 is **replaced**, not dual-written.

## Ingestion

| Core | Pattern | Runtime |
|------|---------|---------|
| A Mainframe | Nightly file → GCS → parse copybook/fixed-width → upsert | Python Cloud Run Job |
| B Events | Kafka / webhook / MQ / REST → bus → consumer | Java Spring |
| C ETL | Scheduled extract from warehouse/API | Python/Java job (Composer/Dataflow optional) |

All paths share one **canonicalizer** and merge policy.

## Canonical bridge

`Party` + `Account` + `AccountPartyRole` + `ExternalIdentifier` collapse account-centric and customer-centric sources without losing lineage (`source_*` projections retained).

## Stack

- **GCP**: GCS, Cloud Run, Cloud SQL Postgres, Pub/Sub or org Kafka, Secret Manager, KMS, VPC
- **Java/Spring**: events, canonicalization, domain API
- **Python**: mainframe parse + ETL
- **Node**: BFFs + simple UIs

## POC success

Parity with today’s DB2 serving semantics in Postgres + APIs/UIs reading unified data from mainframe batch, at least one event stream, and one ETL feed.
