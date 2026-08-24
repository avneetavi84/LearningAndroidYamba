# Servicing Hub — Legacy Modernization Plan (GCP POC)

## 1. Executive summary

Replace the legacy mainframe nightly VSAM → DB2 serving path with a **cloud-native Servicing Hub** on **GCP**. The hub is the primary backend for self-serve, agent-serve, and domain APIs. It ingests from **three core systems across two lines of business**, collapses shared servicing data into one **canonical data model** in **Cloud SQL (PostgreSQL)**, and serves experiences via **GraphQL orchestration** plus simple web UIs.

The three cores are not three copies of the same platform:

| Core | Line of business | Integration style | Freshness in the hub |
|------|------------------|-------------------|----------------------|
| **Legacy receivables** | Receivables | Mainframe VSAM / COBOL copybook / fixed-width, nightly | Batch (today’s UX waits on this overnight file) |
| **Modernized receivables** | Receivables | Events (Kafka / webhooks / MQ / REST) | Near real-time |
| **Subscriptions** | Subscriptions | ETL (warehouse / lakehouse / scheduled extract) | Batch / micro-batch on the ETL cadence |

**POC “done” means:**

1. Nightly legacy-receivables file (VSAM extract / COBOL copybook / fixed-width) lands in Postgres with parity to today’s DB2 semantics.
2. The modernized receivables core streams creates/updates into the same store.
3. A scheduled ETL path from the **subscriptions** line of business also lands in the store.
4. Unified canonical servicing model (not three siloed schemas), plus an explicit **passthrough** path for edge-case data that stays in the source cores.
5. Self-serve + agent-serve UIs consume through a GraphQL gateway that reads the hub first and fans out to cores only for those edge cases.

---

## 2. Current vs target

| Concern | Today | Target (POC → prod path) |
|---|---|---|
| Legacy receivables intake | VSAM / COBOL batch → mainframe jobs → DB2 | File landing zone → parse/normalize → canonical Postgres |
| Modernized receivables | Already capable of Kafka / webhook / MQ / REST | Event pipeline → canonical store (near real-time UX) |
| Subscriptions LOB | ETL / warehouse feeds, separate from servicing UX | Scheduled ETL connector → canonical store |
| Overnight-batch UX wait | **Applies to the legacy receivables core only** — not to modernized receivables, and not as a blanket statement about “all cores” | Legacy path stays on its nightly window; other cores keep their native freshness |
| System of record for common UX | DB2 (legacy path) + per-core apps | Cloud SQL PostgreSQL for **canonical servicing data** (DB2 **replaced**, not dual-written) |
| Edge-case / core-native data | Often mixed into the same screens or not available | **Not** forced into the hub; GraphQL passthrough to the owning core |
| Consumption | Direct DB / legacy apps | GraphQL gateway → hub domain APIs (majority) + core adapters (long tail); simple web UIs |

Nightly volume (~10k customer/account records on the legacy path) is modest: optimize for **correctness, idempotency, auditability, and operability**, not large-scale Spark. Keep the design cloud-native so volume can grow without redesign.

---

## 3. Target architecture (GCP)

```
┌──────────────────────┐  ┌─────────────────────────┐  ┌────────────────────────┐
│ Legacy receivables   │  │ Modernized receivables  │  │ Subscriptions LOB      │
│ Mainframe VSAM       │  │ Event-capable core      │  │ ETL / warehouse feed   │
│ nightly files        │  │ Kafka / MQ / REST       │  │ scheduled extract      │
└──────────┬───────────┘  └────────────┬────────────┘  └───────────┬────────────┘
           │ ingest                    │ ingest                    │ ingest
           ▼                           ▼                           ▼
     GCS Landing Zone            Pub/Sub / Kafka              Composer /
     (raw + quarantine)          Event Ingress                Dataflow / Run Job
           │                           │                           │
           └──────────────┬────────────┴─────────────┬─────────────┘
                          ▼                          ▼
                   Ingestion Workers          Canonicalizer
                   (Python)                   (Java/Spring)
                          │                          │
                          └────────────┬─────────────┘
                                       ▼
                          Cloud SQL PostgreSQL
                          Servicing Hub
                          (canonical + source projections
                           + outbox + audit)
                                       │
           ┌───────────────────────────┼────────────── core adapters (edge cases)
           │                           │              ┌──────────────┐
           ▼                           │              │ Legacy recv. │
     Domain APIs                       │              │ Modern recv. │
     (Java/Spring)                     │              │ Subscriptions│
           │                           │              └──────┬───────┘
           └───────────┬───────────────┴─────────────────────┘
                       ▼
              GraphQL Gateway
              (experience orchestration)
                       │
              ┌────────┴────────┐
              ▼                 ▼
        Agent UI          Self-serve UI
```

**Read path rule:** UIs talk only to GraphQL. GraphQL prefers the Servicing Hub. It calls a core adapter only when the requested field is classified as **passthrough** (not worth canonicalizing).

### 3.1 Responsibility split by language

| Layer | Language | Why |
|---|---|---|
| Mainframe file parse, copybook/fixed-width decode, subscriptions ETL transforms | **Python** | Strong ecosystem for file formats, pandas/polars for light transforms, fast POC iteration; run as Cloud Run Jobs |
| Event consumers, canonicalization, domain APIs, transactional writes | **Java + Spring Boot** | Reliability, schema evolution, transactional outbox, org preference for core services |
| GraphQL gateway + simple self-serve / agent-serve UIs | **Node** (Apollo/Yoga/Mercurius + React/Next) | Natural fit for experience orchestration and thin UI slice |

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

## 4. Data strategy: canonicalize the common serving model — not every field

Cores disagree today: **account-centric receivables** vs **customer-centric receivables**, plus a **subscriptions** model (plans, billing cycles, entitlements). The hub must publish a **canonical servicing model** for data that is shared, frequently read, and needed by both UIs — while retaining source fidelity for audit and remapping.

### 4.1 What belongs in the hub vs what stays in the core

Use an explicit **80/20 (canonicalize vs passthrough)** policy. If a field is rare, core-native, or expensive to keep consistent, **do not** pull it into Postgres.

| Canonicalize into Servicing Hub | Leave in the owning core (GraphQL passthrough) |
|---|---|
| Party / customer identity and match keys | Core-only product parameters (e.g. a single mainframe transaction code screen) |
| Accounts, balances, status, aging used by both UIs | Reverse/adjust workflows that only the core can execute correctly |
| Party ↔ account roles (joint, guarantor, …) | Letter templates, collector queues, obscure dunning flags |
| Subscription header: plan, status, next bill date, link to party/account | Catalog merchandising, promotion engines, entitlement feature flags |
| External identifiers and source lineage | Writes that are not yet a hub command (pay, reverse, change plan) |
| Change timeline for agent history | Anything that would expand PCI scope without UX value |

**Rule of thumb:** if both self-serve and agent need it on the primary profile, canonicalize it. If only one rare agent screen needs it, passthrough.

### 4.2 Layered store (same Postgres instance, clear schemas)

1. **`source_*` schemas / tables** — faithful projections per core (legacy receivables account-shaped, modernized receivables customer-shaped, subscriptions as delivered). Append-friendly, versioned by batch/event id.
2. **`canonical` schema** — unified servicing entities used by APIs/UIs.
3. **`ops` schema** — ingestion runs, dead letters, idempotency keys, outbox, audit.

### 4.3 Canonical entities (starter)

| Entity | Purpose |
|---|---|
| `Party` | Person/org (legal customer) across receivables **and** subscriptions |
| `CustomerProfile` | Servicing view of the party |
| `Account` | Receivable account / obligation container |
| `AccountPartyRole` | Links parties ↔ accounts (`PRIMARY`, `JOINT`, `GUARANTOR`, …) — **bridges account-based and customer-based receivables** |
| `Balance` / `ReceivableItem` | Amounts, aging, status |
| `Subscription` | Vehicle service entitlement (e.g. BlueCruise, SiriusXM-style media, Autopilot) linked to `Party` / VIN and optionally a loan/lease `Account` |
| `ExternalIdentifier` | `(source_system, entity_type, external_id) → canonical_id` |
| `ChangeEvent` | Normalized history for agent timeline / audit |

**Golden rule:** every canonical row is addressable by stable `canonical_id` and reverse-mappable via `ExternalIdentifier`. Merges/updates from any core resolve through that map (match keys: account number, customer number, subscription id, tax id hash, etc. — finalize with data stewards). The same map is what GraphQL uses to call a core for passthrough fields.

### 4.4 Conflict & merge policy (define in POC)

- **Source precedence matrix** per attribute (e.g., modernized receivables wins `email`; legacy receivables wins `account_status` if both present; subscriptions wins plan/status for subscription fields).
- **Last-write-wins** only where explicitly safe; otherwise field-level merge.
- **Never silently drop** source values that were ingested: keep them in `source_*` + audit.
- Passthrough fields are **not merged**; the owning core is authoritative at read time.

### 4.5 Parity with DB2

- Build a **parity checklist**: table/column inventory of current DB2 serving model → canonical mapping (legacy receivables path only).
- POC acceptance: for a frozen sample night file, row counts + key attribute hashes match expected DB2 extracts (or agreed delta list).

---

## 5. Ingestion patterns (three cores)

### 5.1 Legacy receivables — mainframe nightly (VSAM / COBOL copybook / fixed-width)

This is the **only** core whose servicing UX still waits on an overnight batch today. The hub modernizes that process; it does not impose a nightly delay on the other cores.

**Flow**

1. Secure transfer to `gs://…/raw/legacy-receivables/YYYY-MM-DD/…` (SFTP gateway or existing mainframe export → GCS).
2. Trigger Cloud Run Job: validate file presence, size, checksum, record count.
3. **Python parser**: COBOL copybook → typed records (libraries such as `copybook` / custom EBCDIC + PIC clause decoder). Emit Avro/JSON lines to `validated/`.
4. Quarantine bad records; fail the run if error rate exceeds threshold.
5. Canonicalizer (Spring) upserts via idempotent batch id: `source` write → merge → `canonical`.
6. Mark run complete; metrics + audit.

**Design notes**

- Treat files as **immutable batches**; reprocessing is replay from GCS.
- Support **insert + update** semantics (CDC-like from full/delta extracts — confirm whether files are full refresh or delta).
- Target: finish well inside the **1-hour** historical window (at 10k rows this should be minutes).

### 5.2 Modernized receivables — event-capable (near real-time)

This core already can stream. Agent/self-serve freshness for *its* data should follow the event, not the legacy night file.

**Flow**

1. Ingress adapter accepts **Kafka and/or webhooks/REST** (and MQ via bridge if needed) → normalize to internal envelope.
2. Publish to internal topic (`servicing.inbound.modern-receivables`) on Kafka or Pub/Sub.
3. Spring consumer: validate schema (Schema Registry / JSON Schema), idempotency key = `(source, event_id)`.
4. Write `source` projection → canonicalize → commit; emit domain events via **transactional outbox**.
5. GraphQL/APIs see updates in near real-time; agent UI polls or uses SSE/websocket later.

**Envelope (conceptual)**

```json
{
  "source_system": "MODERN_RECEIVABLES",
  "event_id": "uuid",
  "event_type": "CustomerUpdated",
  "occurred_at": "2026-08-23T22:00:00Z",
  "payload": { },
  "trace_id": "…"
}
```

### 5.3 Subscriptions line of business — ETL / lakehouse-aligned

Not a third receivables clone: a **different LOB** whose customer/subscription facts need to appear on the same servicing profile.

**Flow**

1. Scheduled extraction from org warehouse/lakehouse or vendor API (Composer / Run Job / Dataflow per org standard).
2. Land parquet/CSV in GCS curated path **or** query through existing warehouse.
3. Transform to the same internal inbound model as other batch paths; reuse canonicalizer.
4. Idempotent by `(source_system, business_date, batch_id)`.

**Principle:** all three ingest paths converge on **one canonicalizer**, so merge rules and hub APIs stay consistent. GraphQL passthrough is a **read-time** concern, not a fourth ingest style.

---

## 6. Experience layer: GraphQL orchestration + core passthrough

### 6.1 Recommendation — where GraphQL sits

**GraphQL belongs as the experience orchestration layer above the Servicing Hub, not as the ingestion bus and not as the canonical store.**

| Layer | Job | GraphQL? |
|---|---|---|
| Ingest (files / events / ETL) | Land and validate source payloads | No |
| Canonicalizer | Merge, IDs, conflict policy, Postgres writes | No |
| Domain APIs (Java/Spring) | Bounded-context REST/gRPC over the hub | No — keep these for services, jobs, and the gateway itself |
| **GraphQL gateway (Node)** | One client schema for self-serve + agent; compose hub + cores | **Yes** |
| UIs | Render; never call cores directly | Consume GraphQL only |

This is a **BFF that grew a schema**. REST BFFs still work for the POC, but GraphQL is the better long-term fit because:

1. Self-serve and agent need **different field sets** of the same Party/Account/Subscription.
2. Edge-case fields are naturally **nullable / deferred** and sourced from another resolver.
3. `ExternalIdentifier` gives the gateway a stable way to call the right core without the UI knowing core IDs.
4. You avoid a combinatoric explosion of REST “get profile + extras” endpoints.

**Do not** put merge/conflict logic in resolvers. Resolvers either read already-canonical hub data or proxy a single core. If two cores disagree, that was decided at ingest time in the canonicalizer — or it was never canonicalized and only one core is queried.

### 6.2 Suggested GraphQL shape

```graphql
type Party {
  id: ID!                      # canonical
  displayName: String!         # hub
  accounts: [Account!]!        # hub
  subscriptions: [Subscription!]!  # hub
  # Edge case: not worth modeling in Postgres
  legacyCollectorNotes: [CollectorNote!] @fromCore(system: LEGACY_RECEIVABLES)
}

type Account {
  id: ID!
  accountNumber: String!
  balance: Money!              # hub
  status: AccountStatus!       # hub
  sourceLineage: [Lineage!]!   # hub
  # Edge case: mainframe-only inquiry
  lastMainframeAdjustment: Adjustment @fromCore(system: LEGACY_RECEIVABLES)
}

directive @fromCore(system: CoreSystem!) on FIELD_DEFINITION
```

- Default fields resolve from **Servicing Hub domain APIs** (Postgres).
- `@fromCore` fields resolve through a **core adapter** (REST/SOAP/MQ already exposed by that platform).
- Use DataLoader / batched adapters so a profile query does not N+1 into the mainframe.
- Schema registry + persisted queries for the UIs (fintech-friendly: known operation allowlist).

### 6.3 Implementation options (prefer federation-lite)

| Option | When to use |
|---|---|
| **Single Node GraphQL gateway + resolvers** (Yoga, Apollo Server, Mercurius) | **POC / hackathon** — one schema, hub client + 2–3 adapter stubs |
| **Apollo Federation (hub subgraph + later core subgraphs)** | When a core team can own a subgraph; most legacy cores will not |
| **GraphQL Mesh** wrapping existing OpenAPI/SOAP | Fast adapter generation for passthrough; keep hub subgraph hand-written |
| **Spring GraphQL as the hub subgraph only** | If you want Java to own the canonical schema; Node still composes the supergraph |

**Hackathon default:** one Node gateway. Hub REST underneath. One mocked passthrough field (e.g. `legacyCollectorNotes`) to prove the pattern without boiling the ocean.

### 6.4 Writes and mutations

- **Canonical-safe commands** (update servicing profile fields the hub owns) → hub domain API → Postgres (and outbox if cores must be notified later).
- **Core-native commands** (reverse a mainframe item, change a subscription plan in the subscriptions engine) → GraphQL mutation that **passthroughs** to that core; optionally emit an event so the hub catches up.
- Do not dual-write from the gateway into hub *and* core in one mutation without an outbox/saga. Prefer “core is SoR for that command; hub updates via its normal ingest.”

### 6.5 Latency, failure, and compliance in the gateway

- Hub-backed fields should stay fast (Postgres). Treat core passthrough as **degraded-optional**: if the mainframe adapter times out, return the canonical profile plus `errors` / `null` on the edge field — do not fail the whole servicing page.
- Timeouts and circuit breakers per core adapter (legacy mainframe especially).
- Agent access logs at the gateway (SOX): who requested which passthrough field.
- Self-serve schema is a **restricted view** (fewer types, masked PII); agent schema includes passthrough. Same gateway, different persisted-query sets or `@auth` directives.

---

## 7. Domain APIs (still required under GraphQL)

Expose bounded contexts, not raw tables. GraphQL is a consumer of these APIs, not a replacement for them.

- `GET /parties/{id}`, `GET /accounts/{id}`, `GET /accounts/{id}/parties`
- `GET /customers/{id}/accounts` (customer-centric navigation)
- `GET /parties/{id}/subscriptions`
- Search by external id / account number / customer number / subscription id
- Agent-oriented: recent changes, status, balances

Read from Postgres (same DB as today for latency). Use connection pooling (PgBouncer or Cloud SQL connector). Add read replicas only when needed.

UIs (simple POC):

- Self-serve: my accounts / balances / subscriptions (read-mostly, hub-backed).
- Agent-serve: search, unified servicing profile, source lineage badges, **one passthrough widget** for an edge-case core field.

Visual polish is secondary; **correct unified data + an honest passthrough** is primary.

---

## 8. Reliability, performance, compliance

### 8.1 Reliability

- Idempotent consumers and batch runs.
- Poison-message / quarantine queues; replay tooling.
- Transactional outbox for downstream notifications.
- Exactly-once *effect* via upserts + idempotency keys (not relying on broker magic alone).
- Runbook: reprocess night file, rebuild canonical from `source_*`.
- GraphQL: per-core timeouts, bulkheads, and partial success on passthrough fields.

### 8.2 Performance

- 10k nightly (legacy receivables) is trivial; design indexes for agent search paths.
- Event path (modernized receivables): p99 ingest-to-read target (suggest **&lt; 5s** for POC stretch goal).
- Subscriptions ETL: match the existing warehouse SLA; do not pretend it is event-time unless the LOB emits events later.
- Avoid N+1 in GraphQL (DataLoader); persisted queries only from UIs.

### 8.3 Security & regulatory (PCI / SOX / PII)

- Encrypt in transit (TLS) and at rest (CMEK via KMS).
- Tokenize or vault PAN if cards appear; minimize PCI scope — keep card data out of the hub if possible. Passthrough must not become a back door that copies PAN into gateway logs.
- Column-level controls / views for PII; mask in self-serve.
- Immutable audit log of ingest **and** of agent GraphQL operations (SOX).
- Retention & legal hold policies on GCS + DB.
- Private networking (VPC), no public DB, IAP for admin UIs.
- CI security scans; least-privilege service accounts.

---

## 9. Suggested repo / service layout (when implementation starts)

```
servicing-hub/
  contracts/              # AsyncAPI, OpenAPI, GraphQL SDL, copybook specs
  ingest-legacy-recv/     # Python Cloud Run Job (mainframe files)
  ingest-modern-recv/     # Java Spring consumers + webhook ingress
  ingest-subscriptions/   # Python/Java scheduled ETL
  canonicalizer/          # Java Spring merge engine (shared library or service)
  domain-api/             # Java Spring (hub)
  graphql-gateway/        # Node — orchestration + core adapters
  web-selfserve/          # Node/React
  web-agent/              # Node/React
  infra/                  # Terraform (GCS, Cloud SQL, Run, IAM, Pub/Sub)
  parity/                 # DB2 parity fixtures & diff scripts (legacy receivables)
```

---

## 10. Phased POC roadmap

### Phase 0 — Foundations
- Terraform skeleton: GCS buckets, Cloud SQL Postgres, Secret Manager, one Cloud Run service.
- Canonical schema v0 + `ExternalIdentifier` + ingest run tables.
- Observability baseline.

### Phase 1 — Legacy receivables path + DB2 parity
- Sample copybook + fixed-width fixture (anonymized).
- Python parser → GCS validated → canonical upsert.
- Parity report vs frozen DB2 extract.
- Domain API: get account / customer by id.

### Phase 2 — Modernized receivables events + near real-time
- Webhook + Kafka (or Pub/Sub) ingress.
- Idempotent consumer; agent UI shows **this** core’s update without waiting for the legacy night file.
- Conflict policy v1 documented and enforced in code.

### Phase 3 — Subscriptions ETL + GraphQL + unified UX
- Subscriptions scheduled ETL into the same canonicalizer.
- GraphQL gateway: hub-backed profile query + **one** `@fromCore` passthrough field.
- Self-serve + agent-serve thin UIs against GraphQL.
- Source lineage visible in agent UI.
- Load/soak test (synthetic 10k–100k) and security review checklist.

### Phase 4 — Production hardening (post-POC)
- HA Cloud SQL, backups, PITR, multi-AZ Run.
- Full CMEK, SIEM integration, formal runbooks, DR drill.
- Catalog of canonical vs passthrough fields owned by a data steward.
- Cutover plan: freeze DB2 reads for UX, switch gateway to hub, decommission DB2 serving path.

---

## 11. Key decisions locked for this POC

| Decision | Choice |
|---|---|
| Product name | **Servicing Hub** (not Receivables Hub) |
| Cloud | GCP |
| Serving DB | Cloud SQL PostgreSQL (replace DB2 for canonical servicing data) |
| Dual-write to DB2 | No |
| Languages | Python (files/ETL), Java/Spring (core/events/hub API), Node (GraphQL + UI) |
| Cores in scope | Legacy receivables (mainframe batch), modernized receivables (events), subscriptions LOB (ETL) |
| Overnight UX lag | Legacy receivables only |
| Model strategy | Canonicalize shared servicing data; passthrough rare core-native fields |
| Experience orchestration | GraphQL gateway over hub APIs + core adapters |
| UX | Simple self-serve + agent web apps; focus on hub correctness |
| Volume assumption | ~10k nightly on legacy path + near-real-time events from modernized receivables |

---

## 12. Open items to confirm during implementation kickoff

1. Are legacy receivables files **full refresh** or **deltas** each night?
2. Authoritative **match keys** across receivables cores and subscriptions (account #, customer #, subscription id, SSN/EIN hash, etc.).
3. Org-standard **Kafka vs Pub/Sub** for internal bus.
4. Whether cardholder data must ever touch the hub (PCI scope).
5. Exact DB2 tables required for **parity** in phase 1 (legacy path).
6. First **passthrough field** to implement (candidate: a legacy-only inquiry the agent still needs).
7. Whether self-serve and agent share one GraphQL endpoint with authz, or two persisted-query surfaces.

---

## 13. Immediate next step

When you are ready to build: start **Phase 0 + Phase 1** — infra skeleton, canonical schema, one anonymized legacy-receivables file through to Postgres, parity check, and a single domain API. Then put a thin GraphQL facade in front of it so Phase 2–3 (events, subscriptions ETL, passthrough) plug into the same client contract.

## 14. Related: per-core logical models

Detailed account-based, customer-based, and subscriptions schemas for this auto finance domain (indirect loan/lease + in-vehicle service subscriptions) are in [CORE_DATA_MODELS.md](./CORE_DATA_MODELS.md).

Canonical merged Postgres DDL: [CANONICAL_DDL.md](./CANONICAL_DDL.md) · [`sql/canonical_schema.sql`](./sql/canonical_schema.sql).
