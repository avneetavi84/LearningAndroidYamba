# Hackathon Pitch: Servicing Hub

**Tagline:** One servicing hub. Three cores. Zero DB2 drag.

**Working title:** *Unify* — Canonical servicing on GCP in a weekend

---

## The 30-second pitch

Servicing still sits on a split brain. **Legacy receivables** run mainframe nightly jobs (VSAM/COBOL into DB2), so *those* agent and customer screens wait on overnight batch. A **modernized receivables** core can already stream Kafka/REST. A **subscriptions** line of business lands through ETL. Models do not match (account vs customer vs subscription), and every new channel re-stitches the same cores.

**Servicing Hub** is a GCP-native backbone: ingest those three cores into one PostgreSQL canonical store for the data worth sharing, orchestrate self-serve and agent UX through **GraphQL**, and **passthrough** to a core only when an edge-case field is not worth canonicalizing.

---

## Problem (why judges should care)

| Pain | Reality today |
|------|----------------|
| Legacy gravity | Nightly VSAM → mainframe process → DB2; ~1 hour window — **legacy receivables only** |
| Not all cores are batch | Modernized receivables already stream events; subscriptions arrive on an ETL cadence. UX lag is **not** universal |
| Model chaos | Account-based receivables, customer-based receivables, subscription plans — no single servicing profile |
| Over-canonicalization trap | Some core-native data is rare; copying it into a hub is more cost than value |
| Risk | PCI / SOX / PII on a path that was not built for cloud-native audit |

**Outcome if we do nothing:** every new channel rebuilds the same fragile plumbing — or we boil the ocean trying to warehouse every field.

---

## Solution

A **Servicing Hub** on GCP:

1. **Ingest the three cores** — legacy receivables files, modernized receivables events, subscriptions ETL  
2. **Canonicalize what servicing actually shares** — party + account + roles + subscription header + external IDs  
3. **Orchestrate UX with GraphQL** — one schema for self-serve and agent; hub-first resolvers  
4. **Passthrough the long tail** — GraphQL calls the owning core for edge cases; UIs never shop cores themselves  
5. **Replace DB2** — Cloud SQL PostgreSQL as the new serving store for canonical data (no dual-write crutch)

```
Legacy receivables (nightly files) ──┐
Modernized receivables (events)    ──┼──► Canonicalizer ──► PostgreSQL
Subscriptions LOB (ETL)            ──┘         │
                                               ▼
                                    GraphQL gateway
                                     ├─ hub (default)
                                     └─ core adapters (edge cases)
                                               │
                                    Agent UI + Self-serve UI
```

---

## What we will demo (hackathon story)

**Act 1 — Nightly legacy, modernized**  
Drop a sample COBOL/fixed-width customer+account file → watch it land in Postgres with lineage. Call out: **this** is the overnight path we are replacing — not a claim that every core is batch.

**Act 2 — Near real-time receivables**  
Fire a modernized-receivables event (customer update) → agent UI refreshes **without** waiting for tonight’s mainframe file.

**Act 3 — Subscriptions on the same profile**  
ETL a subscription header onto the same party. One servicing view across two LOBs.

**Act 4 — Unified view + honest passthrough**  
Same screen: canonical fields from the hub, source badges, and one GraphQL field that still reads a core (e.g. a legacy-only collector note) — proving we do not have to model everything.

**Act 5 — Self-serve slice**  
Customer sees accounts / balances / subscription status from the same gateway (hub-backed, no passthrough).

**Wow moment:** three different integration styles, one servicing contract, GraphQL that knows when *not* to copy data.

---

## Why this wins a hackathon

- **Real enterprise problem** — mainframe modernization + events + a second LOB (not a toy CRUD app)  
- **Full vertical slice** — ingest → canonicalize → GraphQL → UI  
- **Judgment, not just plumbing** — canonicalize vs passthrough is an architecture taste judges remember  
- **Clear stack** — Python for files/ETL, Java/Spring for hub/events, Node for GraphQL/UI, GCP primitives  
- **Compliance-aware** — PII masking, audit trail, secrets/KMS, no PAN in gateway logs  
- **Scalable story** — 10k nightly rows for the legacy path; design still fits lakehouse/Kafka org standards  

---

## Scope for the hackathon weekend

### Must-ship (MVP)

- [ ] GCS landing + Python parser for one anonymized **legacy receivables** file  
- [ ] Canonical schema (Party, Account, AccountPartyRole, Subscription, ExternalIdentifier)  
- [ ] Java/Spring hub domain API (get customer/account/subscription, search)  
- [ ] One **modernized receivables** event ingress path (webhook or Pub/Sub/Kafka)  
- [ ] GraphQL gateway: hub-backed profile query  
- [ ] Agent web UI: search + unified profile + source lineage  
- [ ] Self-serve web UI: read-only accounts/balances  
- [ ] Basic ingest run audit + idempotent upserts  

### Nice-to-have (stretch)

- [ ] **Subscriptions** ETL feeder on a scheduler  
- [ ] One `@fromCore` passthrough field on the agent profile  
- [ ] Live SSE/websocket refresh for modernized-receivables events  
- [ ] Parity diff report vs sample “DB2 extract” (legacy path)  
- [ ] Terraform one-command env bootstrap  

### Explicitly out of scope

- Full PCI card vault  
- Canonicalizing every core field  
- Production HA/DR cutover  
- Pixel-perfect design system  

---

## Tech stack (on-brand, judge-friendly)

| Layer | Choice |
|-------|--------|
| Cloud | GCP (Cloud Storage, Cloud Run, Cloud SQL Postgres, Pub/Sub) |
| Batch / files / subscriptions ETL | Python |
| Events + hub APIs | Java + Spring Boot |
| GraphQL orchestration + UI | Node + React |
| Data | PostgreSQL canonical model |

---

## Impact if this graduates past the hackathon

- **Right freshness per core** — events stay near real-time; only legacy receivables remain on a night window until that file path is fully displaced  
- **One integration tax** — new channels plug into GraphQL/hub, not three cores  
- **Cheaper than a total warehouse** — passthrough keeps rare data where it already lives  
- **Exit ramp from DB2** — measurable path to decommission legacy serving tables  
- **Platform pattern** — reusable for other domains stuck between mainframe, events, and ETL  

---

## Team roles (suggested)

| Role | Focus |
|------|--------|
| Data / Python | Copybook parser, GCS jobs, subscriptions ETL stub |
| Platform / Java | Canonicalizer, event consumer, hub domain API |
| Experience / Node | GraphQL gateway, core adapter stub, agent & self-serve UIs |
| Story / demo lead | Sample data, script, parity narrative, passthrough field choice |

---

## Success metrics (end of hackathon)

1. Sample legacy night file processed end-to-end into Postgres  
2. Modernized-receivables event visible in agent UI in seconds (not blocked on batch)  
3. Unified profile from ≥2 source shapes (ideally including a subscription)  
4. Both UIs reading through GraphQL (hub default; optional one passthrough)  

---

## One-liner for the submission form

> Cloud-native Servicing Hub on GCP that replaces legacy receivables mainframe→DB2 batch with a canonical PostgreSQL store, also fed by a modern event-based receivables core and a subscriptions ETL feed—GraphQL orchestrates self-serve and agent UX, passing through to cores only for edge-case data not worth canonicalizing.

---

## Call to action

**Build the hub that lets legacy receivables, modern receivables, and subscriptions share a servicing profile—without pretending every field belongs in one database. Then show it live.**

Detailed architecture: [MODERNIZATION_PLAN.md](./MODERNIZATION_PLAN.md) · [ARCHITECTURE_ONEPAGER.md](./ARCHITECTURE_ONEPAGER.md)
