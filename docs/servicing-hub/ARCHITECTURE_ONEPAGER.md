# Servicing Hub — Architecture One-Pager

Companion to [MODERNIZATION_PLAN.md](./MODERNIZATION_PLAN.md) and [HACKATHON_PITCH.md](./HACKATHON_PITCH.md).

## Problem

Three cores feed servicing experiences, but they are **not the same kind of system**:

- **Legacy receivables** — mainframe VSAM/COBOL nightly → DB2. **This** is the core whose UX still waits on overnight batch.
- **Modernized receivables** — already event-capable (Kafka / webhooks / MQ / REST); near real-time is native.
- **Subscriptions LOB** — predominantly ETL / warehouse, a different line of business that still belongs on the same servicing profile.

Models differ (account-based vs customer-based vs subscription). PCI / SOX / PII apply. Forcing every edge-case field into one warehouse is not worth the lift.

## Solution

GCP **Servicing Hub**: ingest the three cores → **canonical PostgreSQL** for shared servicing data → **GraphQL gateway** for UX orchestration. DB2 is **replaced** for the serving path, not dual-written.

UIs do not call cores by default. GraphQL reads the hub; it **passthroughs** to a core only for rare fields that stay out of the canonical model.

## Ingestion

| Core | LOB | Pattern | Runtime |
|------|-----|---------|---------|
| Legacy receivables | Receivables | Nightly file → GCS → parse copybook/fixed-width → upsert | Python Cloud Run Job |
| Modernized receivables | Receivables | Kafka / webhook / MQ / REST → bus → consumer | Java Spring |
| Subscriptions | Subscriptions | Scheduled ETL from warehouse/API | Python/Java job (Composer/Dataflow optional) |

All ingest paths share one **canonicalizer** and merge policy. GraphQL passthrough is a **read-time** path, not a fourth ingest.

## Canonical vs passthrough

- **Canonicalize:** `Party`, `Account`, `AccountPartyRole`, `Subscription`, balances/status, `ExternalIdentifier`, lineage — data both UIs need on the primary profile.
- **Passthrough:** core-native screens, rare attributes, writes only the source system can execute. Gateway uses `ExternalIdentifier` to call the owning core; timeout must not fail the whole profile.

## GraphQL placement

Experience orchestration **above** the hub:

`UI → GraphQL gateway → hub domain APIs (majority) + core adapters (edge cases)`

Not used for ingest or merge. Domain REST/gRPC stays under the gateway for jobs and internal callers.

## Stack

- **GCP**: GCS, Cloud Run, Cloud SQL Postgres, Pub/Sub or org Kafka, Secret Manager, KMS, VPC
- **Java/Spring**: events, canonicalization, hub domain API
- **Python**: mainframe parse + subscriptions ETL
- **Node**: GraphQL gateway + simple UIs

## POC success

Legacy file parity with today’s DB2 serving semantics in Postgres; modernized-receivables events and subscriptions ETL in the same hub; UIs via GraphQL showing a unified profile plus one demonstrated core passthrough.
