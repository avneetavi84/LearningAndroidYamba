# Servicing Hub — Canonical PostgreSQL Data Model

Executable DDL: [`sql/canonical_schema.sql`](./sql/canonical_schema.sql)

This is the **merged** servicing model that collapses:

| Core | Native root | Lands in hub as |
|------|-------------|-----------------|
| Legacy receivables (account-based) | `ACCOUNT` | `canonical.account` (+ parties via roles) |
| Modernized receivables (customer-based) | `CUSTOMER` + `CONTRACT` | `canonical.party` + `canonical.account` |
| Subscriptions LOB | `SUBSCRIPTION` | `canonical.subscription` (+ catalog) |

UIs and GraphQL read **`canonical`**. Ingest keeps faithful copies under **`source_*`**. Runs, idempotency, outbox, and SOX-ish access logs live in **`ops`**.

---

## Schema map

```
canonical.
  dealer
  party ──┬── party_contact
          ├── account_party_role ── account ──┬── balance_snapshot
          │                                   ├── payment
          │                                   └── vehicle
          └── subscription ── service_product
                              └── (optional) bundled_account_id → account

  external_identifier   → points at exactly one of party|account|vehicle|subscription|dealer
  change_event          → agent timeline

source_legacy_recv.account_raw
source_modern_recv.event_raw
source_subscriptions.subscription_raw

ops.ingest_run | idempotency_key | outbox | quarantine | access_audit
```

---

## Design choices

1. **One `account` table for loan and lease** — discriminated by `product_type` (`AUTO_LOAN` | `AUTO_LEASE`) with loan- and lease-specific columns nullable.
2. **`account_party_role` is the bridge** — legacy “parties on an account” and modern “contracts on a customer” both become party↔account roles (`PRIMARY_OBLIGOR`, `CO_OBLIGOR`, `GUARANTOR`, …).
3. **`primary_party_id` on `account`** — denormalized for fast agent/self-serve profile queries; roles remain authoritative for joints/guarantors.
4. **Money as `*_cents` (BIGINT)** — avoid floating point; `currency_code` default `USD`.
5. **PII minimization** — `tax_id_last4` + `tax_id_token` only; no PAN; emails via `citext`.
6. **`external_identifier`** — every core key maps here so GraphQL can passthrough (`LEGACY_RECEIVABLES` + `ACCOUNT` + `0004458912` → `account_id`).
7. **Source tables stay JSONB-heavy** — POC speed; promote typed source columns later if parity diffs need them.
8. **Views** — `v_party_servicing_profile`, `v_account_current_balance` for gateway resolvers.

---

## Field mapping (cores → canonical)

### Party

| Canonical | Legacy | Modernized | Subscriptions |
|-----------|--------|------------|---------------|
| `party_id` | generated | generated | generated |
| name fields / `display_name` | `PARTY` on account | `CUSTOMER` | billing customer |
| `tax_id_last4` | `ssn_last4` | from tokenized customer | if present |
| `external_identifier` | local `party_id` / account+role | `customer_id` | subscriptions `customer_id` |

### Account (loan / lease)

| Canonical | Legacy | Modernized |
|-----------|--------|------------|
| `legacy_account_number` | `account_number` | `external_account_number` when present |
| `modern_contract_id` | — | `contract_id` |
| `product_type` | `LOAN`/`LEASE` → enum | `AUTO_LOAN`/`AUTO_LEASE` |
| `status`, term, rate, payment, residual | account fields | contract fields |
| `dealer_id` / `vehicle_id` | dealer# / VIN | dealer_id / VIN |
| `account_party_role` | `ACCOUNT_PARTY` | `CONTRACT_PARTY` |

### Subscription

| Canonical | Subscriptions core |
|-----------|-------------------|
| `source_subscription_id` | `subscription_id` |
| `product_sku` | catalog SKU (`BLUECRUISE_1`, …) |
| `party_id` / `vehicle_id` | matched customer / VIN |
| `bundled_account_id` | resolved from `bundled_contract_ref` when possible |
| `status`, period, price, channel | as ETL’d |

### Vehicle

Single `canonical.vehicle` keyed by **VIN** — shared by receivables collateral and subscription entitlement target. `capability_flags` JSONB holds ADAS/hardware eligibility from the subscriptions/telematics side.

---

## Example: Jane Doe (after canonicalize)

```text
party                Jane Doe
external_identifier  MODERN_RECEIVABLES / PARTY / cust_9f2a…

account              AUTO_LOAN, legacy_account_number=0004458912, modern_contract_id=ctr_77c0…
account_party_role   PRIMARY_OBLIGOR → Jane
vehicle              VIN 1F…
balance_snapshot     principal_cents=2840000

subscription         BLUECRUISE_1, source_subscription_id=sub_blu_601
                     bundled_account_id → that account
```

---

## Apply (local / Cloud SQL)

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f docs/servicing-hub/sql/canonical_schema.sql
```

Requires PostgreSQL 14+ recommended (`gen_random_uuid`, `JSONB`). Extensions: `pgcrypto`, `citext`.

---

## Out of scope for this DDL (intentionally)

- Full payment allocation ledger / GL
- Collector notes / promise-to-pay (GraphQL **passthrough** to legacy)
- Telematics entitlement debug flags (passthrough to subscriptions)
- SCD2 history tables (use `change_event` + source raw for POC)
- Row-level security policies (add per environment)

---

## Related

- Per-core logical models: [CORE_DATA_MODELS.md](./CORE_DATA_MODELS.md)
- Architecture: [MODERNIZATION_PLAN.md](./MODERNIZATION_PLAN.md)
