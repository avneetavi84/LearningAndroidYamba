# Receivables Hub — Legacy Mainframe Modernization Plan (GCP POC)

## 1. Executive summary

Replace the legacy mainframe nightly VSAM → DB2 path with a **cloud-native Receivables Hub** on **GCP**. The hub is the single backend for self-serve, agent-serve, and domain APIs. It ingests from **three core receivable systems** with different models (account-based vs customer-based), collapses them into one **canonical data model** in **Cloud SQL (PostgreSQL)**, and serves near-real-time experiences via APIs/BFFs and simple web UIs.

**POC “done” means:**

1. Nightly mainframe file (VSAM extract / COBOL copybook / fixed-width) lands in Postgres with parity to today’s DB2 semantics.
2. At least one event-capable core system streams creates/updates into the same store.
3. A scheduled ETL path from a third receivable core also lands in the store.
4. Unified canonical model (not three siloed schemas).
5. Self-serve + agent-serve UIs and APIs reading from the hub (via BFF/API, same DB for performance).

---

## 2. Current vs target

| Concern | Today | Target (POC → prod path) |
|---|---|---|
| Mainframe intake | VSAM / COBOL batch → mainframe jobs → DB2 | File landing zone → parse/normalize → canonical Postgres |
| Second core | N/A or separate | Kafka / webhook / MQ / REST → event pipeline → canonical store |
| Third core | Batch/ETL to DB2-like stores | Scheduled ETL connector → canonical store |
| System of record for UX | DB2 | Cloud SQL PostgreSQL (DB2 **replaced**, not dual-written) |
| Latency | Nightly (~≤1 hour window) | Batch ≤1 hour; events near real-time for agent/self-serve |
| Consumption | Direct DB / legacy apps | Domain APIs + BFF → Postgres; simple web UIs |

Nightly volume (~10k customer/account records) is modest: optimize for **correctness, idempotency, auditability, and operability**, not large-scale Spark. Keep the design cloud-native so volume can grow without redesign.

---

## 3. Target architecture (GCP)

```
┌─────────────────┐  ┌──────────────────┐  ┌─────────────────┐
│ Core A          │  │ Core B           │  │ Core C          │
│ Mainframe VSAM  │  │ Event-capable    │  │ ETL / warehouse │
│ nightly files   │  │ Kafka/MQ/REST    │  │ lakehouse feed  │
└────────┬────────┘  └────────┬─────────┘  └────────┬────────┘
         │                    │                     │
         ▼                    ▼                     ▼
   GCS Landing Zone     Pub/Sub / Kafka        Composer /
   (raw + quarantine)   Event Ingress          Dataflow / Run Job
         │                    │                     │
         └────────────┬───────┴─────────────┬───────┘
                      ▼                     ▼
              Ingestion Workers      Canonicalizer
              (Python)               (Java/Spring)
                      │                     │
                      └──────────┬──────────┘
                                 ▼
                    Cloud SQL PostgreSQL
                    (canonical + source projections
                     + outbox + audit)
                                 │
                    ┌────────────┼────────────┐
                    ▼            ▼            ▼
              Domain APIs   Agent BFF    Self-serve BFF
              (Java/Spring) (Node)       (Node)
                    │            │            │
                    └────────────┼────────────┘
                                 ▼
                         Web UIs (simple)
```

### 3.1 Responsibility split by language

| Layer | Language | Why |
|---|---|---|
| Mainframe file parse, copybook/fixed-width decode, batch ETL transforms | **Python** | Strong ecosystem for file formats, pandas/polars for light transforms, fast POC iteration; run as Cloud Run Jobs |
| Event consumers, canonicalization, domain APIs, transactional writes | **Java + Spring Boot** | Reliability, schema evolution, transactional outbox, org preference for core services |
| BFF + simple self-serve / agent-serve UIs | **Node** (Nest/Express + React/Next) | Thin aggregation for UX, rapid UI slice |

### 3.2 GCP building blocks (POC-friendly)

| Capability | Service |
|---|---|
| Raw file landing / archive | **Cloud Storage** (raw → validated → curated → quarantine) |
| Batch orchestration | **Cloud Scheduler** + **Cloud Run Jobs** (Composer later if org standard) |
| Heavy/stream ETL (optional) | **Dataflow** if aligning to existing lakehouse; else Run Jobs at 10k scale |
| Messaging | Prefer **org Kafka** if already standard; else **Pub/Sub** for POC. Adapter pattern so either works |
| API runtime | **Cloud Run** (scale-to-zero OK for POC) or GKE if platform standard |
| Database | **Cloud SQL for PostgreSQL** (HA optional in POC; required for prod) |
| Secrets / keys | **Secret Manager** + **Cloud KMS** |
| Identity | **Identity Platform / IAP** + service accounts; fine-grained IAM |
| Observability | Cloud Logging, Monitoring, Error Reporting, OpenTelemetry traces |
| CI/CD | Cloud Build or existing org pipeline |

---

## 4. Data strategy: collapse multiple models into one

Cores disagree today: **account-centric** vs **customer-centric**. The hub must not pick a winner per source — it must publish a **canonical receivables model** while retaining source fidelity for audit and remapping.

### 4.1 Layered store (same Postgres instance, clear schemas)

1. **`source_*` schemas / tables** — faithful projections per core (Core A account-shaped, Core B customer-shaped, Core C as delivered). Append-friendly, versioned by batch/event id.
2. **`canonical` schema** — unified business entities used by APIs/UIs.
3. **`ops` schema** — ingestion runs, dead letters, idempotency keys, outbox, audit.

### 4.2 Canonical entities (starter)

| Entity | Purpose |
|---|---|
| `Party` | Person/org (legal customer) |
| `CustomerProfile` | Servicing view of the party in receivables context |
| `Account` | Receivable account / obligation container |
| `AccountPartyRole` | Links parties ↔ accounts (`PRIMARY`, `JOINT`, `GUARANTOR`, …) — **bridges account-based and customer-based sources** |
| `Balance` / `ReceivableItem` | Amounts, aging, status |
| `ExternalIdentifier` | `(source_system, entity_type, external_id) → canonical_id` |
| `ChangeEvent` | Normalized history for agent timeline / audit |

**Golden rule:** every canonical row is addressable by stable `canonical_id` and reverse-mappable via `ExternalIdentifier`. Merges/updates from any core resolve through that map (match keys: account number, customer number, tax id hash, etc. — finalize with data stewards).

### 4.3 Conflict & merge policy (define in POC)

- **Source precedence matrix** per attribute (e.g., Core B wins `email`; Core A wins `account_status` if both present).
- **Last-write-wins** only where explicitly safe; otherwise field-level merge.
- **Never silently drop** source values: keep them in `source_*` + audit.

### 4.4 Parity with DB2

- Build a **parity checklist**: table/column inventory of current DB2 serving model → canonical mapping.
- POC acceptance: for a frozen sample night file, row counts + key attribute hashes match expected DB2 extracts (or agreed delta list).

---

## 5. Ingestion patterns (three cores)

### 5.1 Core A — Mainframe nightly (VSAM / COBOL copybook / fixed-width)

**Flow**

1. Secure transfer to `gs://…/raw/core-a/YYYY-MM-DD/…` (SFTP gateway or existing mainframe export → GCS).
2. Trigger Cloud Run Job: validate file presence, size, checksum, record count.
3. **Python parser**: COBOL copybook → typed records (libraries such as `copybook` / custom EBCDIC + PIC clause decoder). Emit Avro/JSON lines to `validated/`.
4. Quarantine bad records; fail the run if error rate exceeds threshold.
5. Canonicalizer (Spring) upserts via idempotent batch id: `source` write → merge → `canonical`.
6. Mark run complete; metrics + audit.

**Design notes**

- Treat files as **immutable batches**; reprocessing is replay from GCS.
- Support **insert + update** semantics (CDC-like from full/delta extracts — confirm whether files are full refresh or delta).
- Target: finish well inside the **1-hour** historical window (at 10k rows this should be minutes).

### 5.2 Core B — Event-capable (near real-time)

**Flow**

1. Ingress adapter accepts **Kafka and/or webhooks/REST** (and MQ via bridge if needed) → normalize to internal envelope.
2. Publish to internal topic (`receivables.inbound.core-b`) on Kafka or Pub/Sub.
3. Spring consumer: validate schema (Schema Registry / JSON Schema), idempotency key = `(source, event_id)`.
4. Write `source` projection → canonicalize → commit; emit domain events via **transactional outbox**.
5. APIs see updates in near real-time; agent UI polls or uses SSE/websocket later.

**Envelope (conceptual)**

```json
{
  "source_system": "CORE_B",
  "event_id": "uuid",
  "event_type": "CustomerUpdated",
  "occurred_at": "2026-08-23T22:00:00Z",
  "payload": { },
  "trace_id": "…"
}
```

### 5.3 Core C — ETL / lakehouse-aligned

**Flow**

1. Scheduled extraction from org warehouse/lakehouse or vendor API (Composer / Run Job / Dataflow per org standard).
2. Land parquet/CSV in GCS curated path **or** query through existing warehouse.
3. Transform to same internal inbound model as batch path; reuse canonicalizer.
4. Idempotent by `(source_system, business_date, batch_id)`.

**Principle:** all three paths converge on **one canonicalizer**, so merge rules and APIs stay consistent.

---

## 6. Application & API design

### 6.1 Domain APIs (Java / Spring)

Expose bounded contexts, not raw tables:

- `GET /parties/{id}`, `GET /accounts/{id}`, `GET /accounts/{id}/parties`
- `GET /customers/{id}/accounts` (customer-centric navigation)
- Search by external id / account number / customer number
- Agent-oriented: recent changes, status, balances

Read from Postgres (same DB as today for latency). Use connection pooling (PgBouncer or Cloud SQL connector). Add read replicas only when needed.

### 6.2 BFFs (Node)

- **Self-serve BFF** — customer session, limited fields, consent-aware.
- **Agent-serve BFF** — broader fields, audit “who viewed what”, workstation context.

BFFs aggregate domain APIs; do not re-implement merge logic.

### 6.3 UIs (simple POC)

- Self-serve: lookup my accounts / balances / profile (read-mostly).
- Agent-serve: search customer/account, view unified profile, see source lineage badge (“from Core A/B/C”).

Visual polish is secondary; **correct unified data** is primary.

---

## 7. Reliability, performance, compliance

### 7.1 Reliability

- Idempotent consumers and batch runs.
- Poison-message / quarantine queues; replay tooling.
- Transactional outbox for downstream notifications.
- Exactly-once *effect* via upserts + idempotency keys (not relying on broker magic alone).
- Runbook: reprocess night file, rebuild canonical from `source_*`.

### 7.2 Performance

- 10k nightly is trivial; design indexes for agent search paths.
- Event path: p99 ingest-to-read target (suggest **&lt; 5s** for POC stretch goal).
- Avoid N+1 in BFFs; pagination on search.

### 7.3 Security & regulatory (PCI / SOX / PII)

- Encrypt in transit (TLS) and at rest (CMEK via KMS).
- Tokenize or vault PAN if cards appear; minimize PCI scope — keep card data out of hub if possible.
- Column-level controls / views for PII; mask in self-serve.
- Immutable audit log of ingest + agent access (SOX).
- Retention & legal hold policies on GCS + DB.
- Private networking (VPC), no public DB, IAP for admin UIs.
- CI security scans; least-privilege service accounts.

---

## 8. Suggested repo / service layout (when implementation starts)

```
receivables-hub/
  contracts/           # AsyncAPI, OpenAPI, copybook specs, JSON schemas
  ingest-mainframe/    # Python Cloud Run Job
  ingest-events/       # Java Spring consumers + webhook ingress
  ingest-etl/          # Python/Java scheduled jobs
  canonicalizer/       # Java Spring merge engine (shared library or service)
  domain-api/          # Java Spring
  bff-selfserve/       # Node
  bff-agent/           # Node
  web-selfserve/       # Node/React
  web-agent/           # Node/React
  infra/               # Terraform (GCS, Cloud SQL, Run, IAM, Pub/Sub)
  parity/              # DB2 parity fixtures & diff scripts
```

---

## 9. Phased POC roadmap

### Phase 0 — Foundations
- Terraform skeleton: GCS buckets, Cloud SQL Postgres, Secret Manager, one Cloud Run service.
- Canonical schema v0 + `ExternalIdentifier` + ingest run tables.
- Observability baseline.

### Phase 1 — Mainframe path + DB2 parity
- Sample copybook + fixed-width fixture (anonymized).
- Python parser → GCS validated → canonical upsert.
- Parity report vs frozen DB2 extract.
- Domain API: get account / customer by id.

### Phase 2 — Events + near real-time
- Webhook + Kafka (or Pub/Sub) ingress for Core B.
- Idempotent consumer; agent UI shows update without waiting for nightly.
- Conflict policy v1 documented and enforced in code.

### Phase 3 — ETL core + unified UX
- Core C scheduled ETL into same canonicalizer.
- Self-serve + agent-serve thin UIs via BFFs.
- Source lineage visible in agent UI.
- Load/soak test (synthetic 10k–100k) and security review checklist.

### Phase 4 — Production hardening (post-POC)
- HA Cloud SQL, backups, PITR, multi-AZ Run.
- Full CMEK, SIEM integration, formal runbooks, DR drill.
- Cutover plan: freeze DB2 reads for UX, switch BFFs to hub, decommission DB2 serving path.

---

## 10. Key decisions locked for this POC

| Decision | Choice |
|---|---|
| Cloud | GCP |
| Serving DB | Cloud SQL PostgreSQL (replace DB2) |
| Dual-write to DB2 | No |
| Languages | Python (files/ETL), Java/Spring (core/events/API), Node (BFF/UI) |
| Cores in scope | 3 (mainframe batch, events, ETL) |
| Model strategy | Source projections + canonical model with party↔account roles |
| UX | Simple self-serve + agent web apps; focus on hub correctness |
| Volume assumption | ~10k nightly + near-real-time events |

---

## 11. Open items to confirm during implementation kickoff

1. Are mainframe files **full refresh** or **deltas** each night?
2. Authoritative **match keys** across cores (account #, customer #, SSN/EIN hash, etc.).
3. Org-standard **Kafka vs Pub/Sub** for internal bus.
4. Whether cardholder data must ever touch the hub (PCI scope).
5. Exact DB2 tables required for **parity** in phase 1.

---

## 12. Immediate next step

When you are ready to build: start **Phase 0 + Phase 1** — infra skeleton, canonical schema, one anonymized mainframe file through to Postgres, parity check, and a single domain API used by a stub agent page. That proves the hardest legacy path first, then layer events and ETL on the same canonicalizer.
