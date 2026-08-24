# Hackathon Pitch: Receivables Hub

**Tagline:** One cloud hub. Three cores. Zero DB2 drag.

**Working title:** *Unify* — Canonical receivables on GCP in a weekend

---

## The 30-second pitch

Banks and fintechs still run receivables on mainframe nightly jobs that dump VSAM/COBOL files into DB2—while newer cores already speak Kafka and REST. Agents and customers pay the price: stale data, fragmented account-vs-customer models, and brittle integrations.

**Receivables Hub** is a GCP-native backbone that ingests mainframe files, real-time events, and ETL feeds into one PostgreSQL canonical store—and serves self-serve + agent experiences from the same source of truth.

---

## Problem (why judges should care)

| Pain | Reality today |
|------|----------------|
| Legacy gravity | Nightly VSAM → mainframe process → DB2; ~1 hour batch window |
| Model chaos | One core is account-based, another customer-based—no single view |
| Dual worlds | Modern cores can stream events; UX still waits on overnight batch |
| Risk | PCI / SOX / PII on a path that wasn’t built for cloud-native audit |

**Outcome if we do nothing:** every new channel rebuilds the same fragile plumbing.

---

## Solution

A **Receivables Hub** on GCP:

1. **Ingest anything** — mainframe fixed-width/copybook files, Kafka/webhooks, scheduled ETL  
2. **Collapse models** — party + account + roles + external IDs → one canonical model  
3. **Serve everyone** — domain APIs → BFFs → simple self-serve & agent web UIs  
4. **Replace DB2** — Cloud SQL PostgreSQL as the new serving store (no dual-write crutch)

```
Mainframe files ──┐
Events (Kafka)  ──┼──► Canonicalizer ──► PostgreSQL ──► APIs/UI
ETL feeds       ──┘
```

---

## What we will demo (hackathon story)

**Act 1 — Nightly legacy, modernized**  
Drop a sample COBOL/fixed-width customer+account file → watch it land in Postgres with lineage.

**Act 2 — Near real-time**  
Fire a Core B event (customer update) → agent UI refreshes without waiting for tonight’s batch.

**Act 3 — Unified view**  
Same screen shows one customer/account profile merged from account-centric + customer-centric sources, with “sourced from Core A/B/C” badges.

**Act 4 — Self-serve slice**  
Customer sees their accounts/balances from the same hub.

**Wow moment:** one DB, three pipes, two experiences—built cloud-native, not bolted onto DB2.

---

## Why this wins a hackathon

- **Real enterprise problem** — mainframe modernization + event-driven coexistence (not a toy CRUD app)  
- **Full vertical slice** — ingest → canonicalize → API → UI in one demo  
- **Clear architecture taste** — Python for files, Java/Spring for core/events, Node for BFF/UI, GCP primitives  
- **Compliance-aware** — PII masking, audit trail, secrets/KMS called out (fintech-credible)  
- **Scalable story** — 10k nightly rows for POC; design still fits lakehouse/Kafka org standards  

---

## Scope for the hackathon weekend

### Must-ship (MVP)

- [ ] GCS landing + Python parser for one anonymized mainframe file  
- [ ] Canonical schema (Party, Account, AccountPartyRole, ExternalIdentifier)  
- [ ] Java/Spring domain API (get customer/account, search)  
- [ ] One event ingress path (webhook or Pub/Sub/Kafka)  
- [ ] Agent web UI: search + unified profile + source lineage  
- [ ] Self-serve web UI: read-only accounts/balances  
- [ ] Basic ingest run audit + idempotent upserts  

### Nice-to-have (stretch)

- [ ] Second ETL feeder (Core C) on a scheduler  
- [ ] Live SSE/websocket refresh on agent UI  
- [ ] Parity diff report vs sample “DB2 extract”  
- [ ] Terraform one-command env bootstrap  

### Explicitly out of scope

- Full PCI card vault  
- Production HA/DR cutover  
- Pixel-perfect design system  

---

## Tech stack (on-brand, judge-friendly)

| Layer | Choice |
|-------|--------|
| Cloud | GCP (Cloud Storage, Cloud Run, Cloud SQL Postgres, Pub/Sub) |
| Batch / files | Python |
| Events + APIs | Java + Spring Boot |
| BFF + UI | Node + React |
| Data | PostgreSQL canonical model |

---

## Impact if this graduates past the hackathon

- **Faster agent resolution** — near-real-time instead of “wait for the batch”  
- **One integration tax** — new channels plug into the hub, not three cores  
- **Exit ramp from DB2** — measurable path to decommission legacy serving tables  
- **Platform pattern** — reusable for other domains stuck between mainframe and events  

---

## Team roles (suggested)

| Role | Focus |
|------|--------|
| Data / Python | Copybook parser, GCS jobs, ETL stub |
| Platform / Java | Canonicalizer, event consumer, domain API |
| Experience / Node | BFFs + agent & self-serve UIs |
| Story / demo lead | Sample data, script, parity narrative |

---

## Success metrics (end of hackathon)

1. Sample night file processed end-to-end into Postgres  
2. Event-driven update visible in agent UI in seconds  
3. Unified profile from ≥2 source shapes  
4. Both UIs reading only from the hub APIs  

---

## One-liner for the submission form

> Cloud-native receivables hub on GCP that replaces mainframe→DB2 batch with a canonical PostgreSQL store fed by VSAM files, real-time events, and ETL—powering self-serve and agent experiences from one source of truth.

---

## Call to action

**Build the hub that finally lets legacy and modern receivables speak the same language—then show it live.**

Detailed architecture: [MODERNIZATION_PLAN.md](./MODERNIZATION_PLAN.md) · [ARCHITECTURE_ONEPAGER.md](./ARCHITECTURE_ONEPAGER.md)
