# Core System Data Models — Auto Finance & Vehicle Subscriptions

Domain context: **indirect auto lending** (loan or lease originated through a dealer) plus a **vehicle subscriptions** line of business (e.g. SiriusXM-style audio, BlueCruise / hands-free driving, Autopilot / ADAS packages).

This document describes the **native data models of the three cores** as they exist (or would exist) before Servicing Hub canonicalization. Entity names use a logical model (tables/collections are illustrative).

| Core | Orientation | Primary grain | What it finances / sells |
|------|-------------|---------------|--------------------------|
| Legacy receivables | **Account-based** | One receivable **account** per contract | Auto loan or lease |
| Modernized receivables | **Customer-based** | One **customer** with many products/contracts | Auto loan or lease |
| Subscriptions LOB | **Subscription / entitlement-based** | One **subscription** per service on a vehicle | Connected / ADAS / media services |

---

## Shared business vocabulary (not a shared schema)

| Term | Meaning in this company |
|------|-------------------------|
| **Dealer / Originator** | Franchise or independent dealer that originated the deal (indirect lending) |
| **Applicant / Customer / Obligor** | Person or org that signed the loan/lease |
| **Contract / Account** | The receivable instrument (loan note or lease agreement) |
| **Collateral / Vehicle** | VIN-identified vehicle securing or subject to the contract |
| **Loan** | Closed-end retail installment contract |
| **Lease** | Closed-end consumer lease (capitalized cost, residual, money factor) |
| **Subscription** | Recurring paid entitlement for an in-vehicle service (media, BlueCruise, Autopilot, etc.) |

These words appear in all three cores with **different shapes**. That mismatch is why Servicing Hub exists.

---

## 1. Legacy receivables core — account-based

### 1.1 Design posture

- The **account (contract) is the system of record root**.
- Customers, vehicles, and dealers hang off the account.
- Nightly VSAM / COBOL feeds are typically **account-keyed** files (one record or record-set per account number).
- Joint obligors, guarantors, and co-lessees are **roles on the account**, not first-class customer hierarchies.

### 1.2 Entity-relationship (logical)

```
DEALER 1──* ACCOUNT *──1 VEHICLE
              │
              ├──* ACCOUNT_PARTY (role: PRIMARY, JOINT, GUARANTOR, CO_LESSEE)
              │         │
              │         └──> PARTY (thin; often not a global customer master)
              │
              ├──* ACCOUNT_BALANCE / AGING
              ├──* PAYMENT / TRANSACTION
              ├──* FEE / LATE_CHARGE
              └──* COLLECTION_ACTIVITY
```

### 1.3 Entities & key attributes

#### `ACCOUNT` (root)

| Attribute | Type / notes |
|-----------|----------------|
| `account_number` | PK — legacy account / contract number |
| `product_type` | `LOAN` \| `LEASE` |
| `account_status` | e.g. `ACTIVE`, `PAID_OFF`, `CHARGED_OFF`, `REPO`, `CLOSED` |
| `origination_date` | Deal booking date |
| `maturity_date` | Final payment / lease end |
| `term_months` | Contract term |
| `apr` / `money_factor` | Loan APR or lease money factor |
| `amount_financed` / `capitalized_cost` | Loan principal or lease cap cost |
| `residual_value` | Lease only |
| `payment_amount` | Scheduled periodic payment |
| `payment_frequency` | `MONTHLY` (typical) |
| `next_due_date` | |
| `days_past_due` | |
| `dealer_number` | FK → `DEALER` |
| `vin` | FK → `VEHICLE` (often denormalized on the account record) |
| `branch` / `portfolio` / `book` | Legacy bookkeeping dimensions |
| `last_maintenance_ts` | From nightly batch |

#### `PARTY` (account-scoped identity)

Legacy systems often store party **on the account**, not as a reusable enterprise customer.

| Attribute | Type / notes |
|-----------|----------------|
| `party_id` | Local id (may be account+sequence, not global) |
| `tax_id_masked` / `ssn_last4` | PII — constrained |
| `name_first`, `name_last`, `name_full` | |
| `date_of_birth` | |
| `address_*`, `phone_*`, `email` | Often mailing address for statements |
| `customer_type` | `INDIVIDUAL` \| `BUSINESS` |

#### `ACCOUNT_PARTY`

| Attribute | Type / notes |
|-----------|----------------|
| `account_number` | FK |
| `party_id` | FK |
| `role` | `PRIMARY`, `JOINT`, `GUARANTOR`, `CO_LESSEE` |
| `liability_pct` | Optional |

#### `VEHICLE` (collateral)

| Attribute | Type / notes |
|-----------|----------------|
| `vin` | PK |
| `year`, `make`, `model`, `trim` | |
| `mileage_at_origination` | |
| `new_used` | `NEW` \| `USED` |
| `vehicle_value` / `MSRP` / `invoice` | Origination valuation |

#### `DEALER`

| Attribute | Type / notes |
|-----------|----------------|
| `dealer_number` | PK |
| `dealer_name` | |
| `dealer_state` | |

#### `ACCOUNT_BALANCE`

| Attribute | Type / notes |
|-----------|----------------|
| `account_number` | FK |
| `as_of_date` | |
| `principal_balance` / `net_investment` | Loan vs lease wording |
| `interest_accrued`, `fees_due`, `total_amount_due` | |
| `payoff_amount` | |
| `aging_bucket` | `CURRENT`, `30`, `60`, `90`, `120+` |

#### `PAYMENT` / `TRANSACTION`

| Attribute | Type / notes |
|-----------|----------------|
| `account_number` | FK / leading key |
| `txn_id` | |
| `txn_date`, `posting_date` | |
| `txn_type` | `PAYMENT`, `NSF`, `FEE`, `ADJUSTMENT`, `EXTENSION` |
| `amount`, `method` | ACH, card token ref, check, dealer |

#### `COLLECTION_ACTIVITY` (often passthrough candidate)

| Attribute | Type / notes |
|-----------|----------------|
| `account_number` | |
| `activity_ts`, `collector_id`, `note_text`, `promise_to_pay_date` | High volume, core-native |

### 1.4 Typical nightly file grain

- Primary extract keyed by **`account_number`**
- Nested or companion files: parties-by-account, balances, payments-since-yesterday
- ~10k account/customer-related records per night (new + updates)

### 1.5 How agents navigate today

Search → **account number** (or VIN / name scan that resolves to accounts) → account screen → parties listed as roles on that account.

---

## 2. Modernized receivables core — customer-based

### 2.1 Design posture

- The **customer is the system of record root**.
- Loans and leases are **products / contracts owned by the customer** (and related parties via a party graph).
- Designed for events: `CustomerCreated`, `CustomerUpdated`, `ContractBooked`, `PaymentPosted`, etc.
- Better fit for CRM-style servicing: one profile, many obligations.

### 2.2 Entity-relationship (logical)

```
CUSTOMER 1──* CUSTOMER_CONTACT
    │
    ├──* CUSTOMER_RELATIONSHIP (HOUSEHOLD / RELATED_PARTY)
    │
    └──* CONTRACT (loan or lease)
              │
              ├──* CONTRACT_PARTY (role relative to contract)
              ├── 1 VEHICLE
              ├──* SCHEDULE / BILLING_INSTRUCTION
              ├──* BALANCE_SNAPSHOT
              └──* PAYMENT_EVENT
```

### 2.3 Entities & key attributes

#### `CUSTOMER` (root)

| Attribute | Type / notes |
|-----------|----------------|
| `customer_id` | PK — durable UUID / snowflake |
| `customer_status` | `PROSPECT`, `ACTIVE`, `INACTIVE`, `BLOCKED` |
| `customer_type` | `INDIVIDUAL` \| `ORGANIZATION` |
| `legal_name` / structured name fields | |
| `tax_id_token` | Vaulted / tokenized — not raw SSN in clear |
| `date_of_birth` / `incorporation_date` | |
| `preferred_language`, `preferred_channel` | Servicing prefs |
| `credit_tier_at_booking` | Optional analytics attribute |
| `created_at`, `updated_at` | Event-time friendly |
| `version` | Optimistic concurrency for event upserts |

#### `CUSTOMER_CONTACT`

| Attribute | Type / notes |
|-----------|----------------|
| `customer_id` | FK |
| `contact_type` | `EMAIL`, `MOBILE`, `HOME_PHONE`, `MAILING`, `GARAGING` |
| `value` / address components | |
| `is_primary`, `verified`, `consent_marketing` | |

#### `CUSTOMER_RELATIONSHIP`

| Attribute | Type / notes |
|-----------|----------------|
| `from_customer_id`, `to_customer_id` | |
| `relationship_type` | `SPOUSE`, `HOUSEHOLD`, `GUARANTOR_OF`, `AUTHORIZED_USER` |

Supports customer-centric navigation that legacy account files struggle with (household view).

#### `CONTRACT` (loan or lease product)

| Attribute | Type / notes |
|-----------|----------------|
| `contract_id` | PK |
| `customer_id` | FK — **primary billing customer** (owner of the profile) |
| `external_account_number` | May map to legacy `account_number` when converted/migrated |
| `product_type` | `AUTO_LOAN` \| `AUTO_LEASE` |
| `product_code` / `program_code` | Indirect program (subvention, captive, etc.) |
| `status` | `PENDING`, `BOOKED`, `ACTIVE`, `PAID_OFF`, `CHARGED_OFF`, `TERMINATED` |
| `origination_channel` | `INDIRECT_DEALER` |
| `dealer_id` | |
| `term_months`, `rate`, `payment_amount`, `frequency` | |
| `amount_financed` / `capitalized_cost`, `residual_value` | |
| `booked_at`, `maturity_at` | |
| `servicing_flag_set` | JSON/flags for modern workflows |

#### `CONTRACT_PARTY`

| Attribute | Type / notes |
|-----------|----------------|
| `contract_id` | |
| `customer_id` | FK to customer master |
| `role` | `PRIMARY_OBLIGOR`, `CO_OBLIGOR`, `GUARANTOR`, `CO_LESSEE` |

Unlike legacy, parties are **real customer records**, not thin account embeds.

#### `VEHICLE`

Same business meaning as legacy; typically referenced from `CONTRACT`.

| Attribute | Type / notes |
|-----------|----------------|
| `vehicle_id` | PK |
| `vin` | Unique |
| `year`, `make`, `model`, `trim`, `odometer` | |
| `garaging_address` | May differ from customer mailing |

#### `BALANCE_SNAPSHOT` / `PAYMENT_EVENT`

Event-sourced friendly:

| `BALANCE_SNAPSHOT` | `as_of`, `principal`, `fees`, `total_due`, `days_past_due`, `payoff` |
| `PAYMENT_EVENT` | `event_id`, `contract_id`, `customer_id`, `amount`, `posted_at`, `method`, `allocation` |

### 2.4 Typical event grain

- Envelope keyed by **`customer_id`** and/or **`contract_id`**
- Downstream hub upserts use `(source_system, event_id)` for idempotency
- Near real-time: agent profile can refresh when `CustomerUpdated` / `PaymentPosted` arrives — **not** blocked on the legacy night file

### 2.5 How agents navigate

Search → **customer** → list of contracts (loan/lease) → drill into one contract / vehicle.

---

## 3. Subscriptions line of business — entitlement / subscription-based

### 3.1 Design posture

- Root is the **subscription** (or entitlement) for a **service product** on a **vehicle**, billed to a **customer**.
- Not a loan book: recurring commerce (trial, paid, cancel, renew) for in-car services such as:
  - **SiriusXM-style** audio / media
  - **BlueCruise**-style hands-free highway driving
  - **Autopilot / ADAS** feature packages
  - Similar connected-services SKUs
- Predominantly **ETL** into Servicing Hub (warehouse extract); may later add events.

### 3.2 Entity-relationship (logical)

```
CUSTOMER 1──* SUBSCRIPTION *──1 VEHICLE
                 │
                 ├── 1 SERVICE_PRODUCT (catalog)
                 ├──* SUBSCRIPTION_STATUS_HISTORY
                 ├──* BILLING_PERIOD / INVOICE_LINE
                 └──* ENTITLEMENT_FLAG (what the car is allowed to do)
```

Optional: link to a receivables **contract** when the subscription was bundled at F&I / lease signing.

```
SUBSCRIPTION >── optional ──< CONTRACT (loan/lease in a receivables core)
```

### 3.3 Entities & key attributes

#### `SERVICE_PRODUCT` (catalog)

| Attribute | Type / notes |
|-----------|----------------|
| `product_sku` | PK — e.g. `SXM_PREMIUM`, `BLUECRUISE_1`, `AUTOPILOT_ENHANCED` |
| `product_family` | `MEDIA`, `DRIVER_ASSIST`, `CONNECTIVITY`, `MAPS` |
| `display_name` | “BlueCruise”, “SiriusXM Premier”, … |
| `billing_model` | `MONTHLY`, `ANNUAL`, `PREPAID_TERM`, `INCLUDED_WITH_LEASE` |
| `is_vehicle_bound` | Almost always `true` for these SKUs |
| `oem_feature_code` | Code pushed to the vehicle / telematics |

#### `SUBSCRIPTION` (root for this LOB)

| Attribute | Type / notes |
|-----------|----------------|
| `subscription_id` | PK |
| `customer_id` | Who is billed / owns the subscription |
| `vin` / `vehicle_id` | Vehicle the entitlement attaches to |
| `product_sku` | FK → catalog |
| `status` | `TRIAL`, `ACTIVE`, `PAST_DUE`, `SUSPENDED`, `CANCELLED`, `EXPIRED` |
| `start_at`, `current_period_end`, `cancel_at`, `trial_end_at` | |
| `price_cents`, `currency`, `tax_exempt` | |
| `bundled_contract_ref` | Optional opaque ref to loan/lease account or contract id |
| `sales_channel` | `DEALER_F_AND_I`, `IN_APP`, `WEB`, `OEM_PROMOTION` |
| `telematics_enrollment_id` | Bridge to OEM backend |
| `last_etl_batch_id` | Lineage from warehouse load |

#### `ENTITLEMENT_FLAG`

| Attribute | Type / notes |
|-----------|----------------|
| `subscription_id` | |
| `feature_code` | e.g. `BLUECRUISE_ENGAGED_ALLOWED` |
| `enabled` | Derived from status + vehicle capability |
| `effective_from`, `effective_to` | |

#### `BILLING_PERIOD` / `INVOICE_LINE`

| Attribute | Type / notes |
|-----------|----------------|
| `subscription_id` | |
| `period_start`, `period_end` | |
| `amount`, `tax`, `status` | `PENDING`, `PAID`, `FAILED`, `WAIVED` |
| `payment_method_token` | PCI-sensitive — prefer token only |

#### `VEHICLE` (subscriptions view)

May overlap receivables vehicle master but often mastered in telematics:

| Attribute | Type / notes |
|-----------|----------------|
| `vin` | |
| `capability_flags` | Hardware supports BlueCruise / Autopilot tier |
| `oem_model_year_platform` | Determines eligible SKUs |

#### `CUSTOMER` (subscriptions view)

Often a **lighter** customer than modernized receivables — email-first, OEM identity, or shared CIF. ETL should still carry a match key (`customer_id`, email hash, or VIN+name) for Servicing Hub party resolution.

### 3.4 Typical ETL grain

- Extract keyed by **`subscription_id`** (and `vin`, `customer_id`)
- Daily or intra-day warehouse → GCS / hub job
- Soft deletes / status transitions as SCD Type 2 in warehouse, Type 1 upsert in hub for POC

### 3.5 How agents navigate

Search customer or VIN → see **active subscriptions** alongside loan/lease obligations on one servicing profile (after hub merge).

---

## 4. Side-by-side comparison (why canonicalization is hard)

| Concept | Legacy receivables | Modernized receivables | Subscriptions |
|---------|--------------------|------------------------|---------------|
| Root entity | `ACCOUNT` | `CUSTOMER` | `SUBSCRIPTION` |
| Loan/lease | The account itself | `CONTRACT` under customer | N/A (optional bundle ref) |
| Customer | Thin `PARTY` on account | First-class `CUSTOMER` | Billing customer (may be lighter) |
| Vehicle | Collateral on account | Asset on contract | Entitlement target (capabilities matter) |
| Money movement | Payment/txn on account | Payment events on contract/customer | Recurring invoice on subscription |
| Identity key agents use | Account number | Customer id | Subscription id / VIN |
| Integration | Nightly files | Events | ETL |
| Freshness | Overnight batch | Near real-time | ETL cadence |

---

## 5. Minimal example (same human, three shapes)

**Deal:** Jane Doe finances a 2026 SUV at Harbor Motors (indirect loan) and adds BlueCruise monthly.

### Legacy receivables row (conceptual)

```text
ACCOUNT 0004458912
  product_type=LOAN  status=ACTIVE  vin=1F…  dealer=HARBOR
  ACCOUNT_PARTY role=PRIMARY → "DOE,JANE" ssn_last4=6789
  BALANCE principal=28,400  next_due=2026-09-01
```

### Modernized receivables documents (conceptual)

```text
CUSTOMER cust_9f2a…
  name=Jane Doe  email=jane@…
  CONTRACT ctr_77c0… type=AUTO_LOAN status=ACTIVE
    vin=1F…  external_account_number=0004458912
    CONTRACT_PARTY role=PRIMARY_OBLIGOR → cust_9f2a…
```

### Subscriptions row (conceptual)

```text
SUBSCRIPTION sub_blu_601
  customer_id=cust_9f2a…  vin=1F…
  product_sku=BLUECRUISE_1  status=ACTIVE
  price=4999 USD/month  sales_channel=DEALER_F_AND_I
  bundled_contract_ref=ctr_77c0…
```

Servicing Hub would collapse these into one **Party** with an **Account/Contract**, a **Subscription**, and `ExternalIdentifier` rows pointing back to `0004458912`, `cust_9f2a…`, `sub_blu_601`.

---

## 6. Mapping hints toward Servicing Hub

| Canonical hub entity | Legacy source | Modernized source | Subscriptions source |
|----------------------|---------------|-------------------|----------------------|
| `Party` | `PARTY` / primary `ACCOUNT_PARTY` | `CUSTOMER` | Subscription customer |
| `Account` | `ACCOUNT` | `CONTRACT` | — |
| `AccountPartyRole` | `ACCOUNT_PARTY.role` | `CONTRACT_PARTY.role` | — |
| `Vehicle` | `VEHICLE` on account | `VEHICLE` on contract | `VEHICLE` on subscription |
| `Balance` | `ACCOUNT_BALANCE` | `BALANCE_SNAPSHOT` | — (or invoice due) |
| `Subscription` | — | — | `SUBSCRIPTION` + product |
| `ExternalIdentifier` | `account_number`, local `party_id` | `customer_id`, `contract_id` | `subscription_id`, OEM ids |

**Passthrough candidates** (keep in core, expose via GraphQL when needed): legacy `COLLECTION_ACTIVITY`, modernized workflow flags, subscription `ENTITLEMENT_FLAG` / telematics debug, OEM capability matrices.

**Executable merge:** Postgres DDL + mapping notes are in [CANONICAL_DDL.md](./CANONICAL_DDL.md) and [`sql/canonical_schema.sql`](./sql/canonical_schema.sql).

---

## 7. Open modeling choices (confirm with domain stewards)

1. **Lease vs loan** — single `ACCOUNT`/`CONTRACT` with `product_type`, or separate subtype tables?
2. **Business / commercial** obligors — in scope for POC or consumer-only?
3. **VIN as join key** across receivables and subscriptions — reliable enough, or need OEM vehicle id?
4. **Bundled subscriptions** — is `bundled_contract_ref` populated at F&I today, or inferred later?
5. **Customer match** across modernized receivables and subscriptions — shared CIF or probabilistic match (email / phone / VIN)?

---

## Related docs

- [MODERNIZATION_PLAN.md](./MODERNIZATION_PLAN.md) — hub architecture, GraphQL passthrough
- [ARCHITECTURE_ONEPAGER.md](./ARCHITECTURE_ONEPAGER.md)
- [HACKATHON_PITCH.md](./HACKATHON_PITCH.md)
