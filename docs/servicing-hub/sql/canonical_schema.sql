-- Servicing Hub — canonical PostgreSQL DDL (POC)
-- Domain: indirect auto loan/lease + vehicle subscriptions (media / BlueCruise / Autopilot)
-- Merges: legacy account-based receivables, modernized customer-based receivables, subscriptions ETL
--
-- Schemas:
--   canonical  — unified servicing model read by domain APIs / GraphQL
--   source_*   — faithful per-core projections (audit + re-canonicalize)
--   ops        — ingest runs, idempotency, outbox, access audit
--
-- Apply: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f canonical_schema.sql

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;    -- case-insensitive email

-- ---------------------------------------------------------------------------
-- Schemas
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS canonical;
CREATE SCHEMA IF NOT EXISTS source_legacy_recv;
CREATE SCHEMA IF NOT EXISTS source_modern_recv;
CREATE SCHEMA IF NOT EXISTS source_subscriptions;
CREATE SCHEMA IF NOT EXISTS ops;

-- ---------------------------------------------------------------------------
-- Shared enums (canonical)
-- ---------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE canonical.source_system AS ENUM (
    'LEGACY_RECEIVABLES',
    'MODERN_RECEIVABLES',
    'SUBSCRIPTIONS'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE canonical.party_type AS ENUM ('INDIVIDUAL', 'ORGANIZATION');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE canonical.account_product_type AS ENUM ('AUTO_LOAN', 'AUTO_LEASE');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE canonical.account_status AS ENUM (
    'PENDING', 'BOOKED', 'ACTIVE', 'PAID_OFF', 'CHARGED_OFF',
    'REPO', 'TERMINATED', 'CLOSED'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE canonical.party_account_role AS ENUM (
    'PRIMARY_OBLIGOR', 'CO_OBLIGOR', 'GUARANTOR', 'CO_LESSEE', 'AUTHORIZED_USER'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE canonical.aging_bucket AS ENUM (
    'CURRENT', 'DPD_1_29', 'DPD_30_59', 'DPD_60_89', 'DPD_90_119', 'DPD_120_PLUS'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE canonical.subscription_status AS ENUM (
    'TRIAL', 'ACTIVE', 'PAST_DUE', 'SUSPENDED', 'CANCELLED', 'EXPIRED'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE canonical.product_family AS ENUM (
    'MEDIA', 'DRIVER_ASSIST', 'CONNECTIVITY', 'MAPS', 'OTHER'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE canonical.billing_model AS ENUM (
    'MONTHLY', 'ANNUAL', 'PREPAID_TERM', 'INCLUDED_WITH_LEASE'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE canonical.sales_channel AS ENUM (
    'DEALER_F_AND_I', 'IN_APP', 'WEB', 'OEM_PROMOTION', 'OTHER'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE canonical.payment_frequency AS ENUM (
    'MONTHLY', 'BIWEEKLY', 'WEEKLY', 'OTHER'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE canonical.external_entity_type AS ENUM (
    'PARTY', 'ACCOUNT', 'VEHICLE', 'SUBSCRIPTION', 'DEALER', 'PAYMENT', 'OTHER'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------------------
-- canonical.dealer
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.dealer (
  dealer_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dealer_number       TEXT NOT NULL,
  dealer_name         TEXT NOT NULL,
  state_code          CHAR(2),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_dealer_number UNIQUE (dealer_number)
);

-- ---------------------------------------------------------------------------
-- canonical.party  (customer / obligor across LOBs)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.party (
  party_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  party_type          canonical.party_type NOT NULL DEFAULT 'INDIVIDUAL',
  display_name        TEXT NOT NULL,
  name_prefix         TEXT,
  name_first          TEXT,
  name_middle         TEXT,
  name_last           TEXT,
  name_suffix         TEXT,
  legal_name          TEXT,                          -- organizations
  date_of_birth       DATE,
  tax_id_last4        CHAR(4),                       -- never store full SSN/EIN here
  tax_id_token        TEXT,                          -- vault/token reference
  preferred_language  TEXT,
  preferred_channel   TEXT,
  status              TEXT NOT NULL DEFAULT 'ACTIVE',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_from        canonical.source_system,
  updated_from        canonical.source_system
);

CREATE INDEX IF NOT EXISTS ix_party_name_last_first
  ON canonical.party (name_last, name_first);
CREATE INDEX IF NOT EXISTS ix_party_tax_last4
  ON canonical.party (tax_id_last4)
  WHERE tax_id_last4 IS NOT NULL;

-- ---------------------------------------------------------------------------
-- canonical.party_contact
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.party_contact (
  party_contact_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  party_id            UUID NOT NULL REFERENCES canonical.party (party_id),
  contact_type        TEXT NOT NULL,  -- EMAIL | MOBILE | HOME_PHONE | MAILING | GARAGING
  email               CITEXT,
  phone_e164          TEXT,
  address_line1       TEXT,
  address_line2       TEXT,
  city                TEXT,
  state_code          CHAR(2),
  postal_code         TEXT,
  country_code        CHAR(2) DEFAULT 'US',
  is_primary          BOOLEAN NOT NULL DEFAULT false,
  is_verified         BOOLEAN NOT NULL DEFAULT false,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_party_contact_has_value CHECK (
    email IS NOT NULL OR phone_e164 IS NOT NULL OR address_line1 IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS ix_party_contact_party
  ON canonical.party_contact (party_id);
CREATE INDEX IF NOT EXISTS ix_party_contact_email
  ON canonical.party_contact (email)
  WHERE email IS NOT NULL;

-- ---------------------------------------------------------------------------
-- canonical.vehicle
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.vehicle (
  vehicle_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vin                 CHAR(17) NOT NULL,
  model_year          INT,
  make                TEXT,
  model               TEXT,
  trim                TEXT,
  new_used            TEXT,               -- NEW | USED
  odometer            INT,
  msrp_cents          BIGINT,
  capability_flags    JSONB NOT NULL DEFAULT '{}'::jsonb,  -- BlueCruise/Autopilot hardware etc.
  oem_platform        TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_vehicle_vin UNIQUE (vin),
  CONSTRAINT ck_vin_len CHECK (char_length(vin) = 17)
);

CREATE INDEX IF NOT EXISTS ix_vehicle_ymmt
  ON canonical.vehicle (model_year, make, model);

-- ---------------------------------------------------------------------------
-- canonical.account  (loan or lease — merges legacy ACCOUNT + modern CONTRACT)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.account (
  account_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_type        canonical.account_product_type NOT NULL,
  status              canonical.account_status NOT NULL DEFAULT 'ACTIVE',
  -- Display / search aids from either core
  legacy_account_number TEXT,            -- legacy account_number when known
  modern_contract_id    TEXT,            -- modernized contract_id when known
  dealer_id           UUID REFERENCES canonical.dealer (dealer_id),
  vehicle_id          UUID REFERENCES canonical.vehicle (vehicle_id),
  origination_channel TEXT NOT NULL DEFAULT 'INDIRECT_DEALER',
  origination_date    DATE,
  booked_at           TIMESTAMPTZ,
  maturity_date       DATE,
  term_months         INT,
  payment_amount_cents BIGINT,
  payment_frequency   canonical.payment_frequency DEFAULT 'MONTHLY',
  currency_code       CHAR(3) NOT NULL DEFAULT 'USD',
  -- Loan-oriented
  apr_bps             INT,               -- e.g. 649 = 6.49%
  amount_financed_cents BIGINT,
  -- Lease-oriented
  money_factor        NUMERIC(12, 8),
  capitalized_cost_cents BIGINT,
  residual_value_cents BIGINT,
  next_due_date       DATE,
  days_past_due       INT NOT NULL DEFAULT 0,
  program_code        TEXT,
  primary_party_id    UUID REFERENCES canonical.party (party_id),  -- denormalized for fast profile
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_from        canonical.source_system,
  updated_from        canonical.source_system,
  CONSTRAINT ck_account_has_source_key CHECK (
    legacy_account_number IS NOT NULL OR modern_contract_id IS NOT NULL
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_account_legacy_number
  ON canonical.account (legacy_account_number)
  WHERE legacy_account_number IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_account_modern_contract
  ON canonical.account (modern_contract_id)
  WHERE modern_contract_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_account_primary_party
  ON canonical.account (primary_party_id);
CREATE INDEX IF NOT EXISTS ix_account_vehicle
  ON canonical.account (vehicle_id);
CREATE INDEX IF NOT EXISTS ix_account_status
  ON canonical.account (status);
CREATE INDEX IF NOT EXISTS ix_account_next_due
  ON canonical.account (next_due_date);

-- ---------------------------------------------------------------------------
-- canonical.account_party_role  (bridges account-based ↔ customer-based)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.account_party_role (
  account_party_role_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id          UUID NOT NULL REFERENCES canonical.account (account_id) ON DELETE CASCADE,
  party_id            UUID NOT NULL REFERENCES canonical.party (party_id),
  role                canonical.party_account_role NOT NULL,
  liability_pct       NUMERIC(5, 2),
  effective_from      DATE,
  effective_to        DATE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_account_party_role UNIQUE (account_id, party_id, role)
);

CREATE INDEX IF NOT EXISTS ix_apr_party
  ON canonical.account_party_role (party_id);

-- ---------------------------------------------------------------------------
-- canonical.balance_snapshot
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.balance_snapshot (
  balance_snapshot_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id          UUID NOT NULL REFERENCES canonical.account (account_id) ON DELETE CASCADE,
  as_of_date          DATE NOT NULL,
  as_of_ts            TIMESTAMPTZ NOT NULL DEFAULT now(),
  principal_cents     BIGINT NOT NULL DEFAULT 0,       -- or net investment for lease
  interest_accrued_cents BIGINT NOT NULL DEFAULT 0,
  fees_due_cents      BIGINT NOT NULL DEFAULT 0,
  total_amount_due_cents BIGINT NOT NULL DEFAULT 0,
  payoff_cents        BIGINT,
  aging_bucket        canonical.aging_bucket NOT NULL DEFAULT 'CURRENT',
  source_system       canonical.source_system NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_balance_account_as_of UNIQUE (account_id, as_of_date, source_system)
);

CREATE INDEX IF NOT EXISTS ix_balance_account_as_of
  ON canonical.balance_snapshot (account_id, as_of_date DESC);

-- ---------------------------------------------------------------------------
-- canonical.payment  (normalized recent payments for servicing UI)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.payment (
  payment_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id          UUID NOT NULL REFERENCES canonical.account (account_id),
  party_id            UUID REFERENCES canonical.party (party_id),
  source_system       canonical.source_system NOT NULL,
  source_txn_id       TEXT NOT NULL,
  posted_at           TIMESTAMPTZ NOT NULL,
  effective_date      DATE,
  amount_cents        BIGINT NOT NULL,
  currency_code       CHAR(3) NOT NULL DEFAULT 'USD',
  method              TEXT,               -- ACH | CARD_TOKEN | CHECK | DEALER | OTHER
  txn_type            TEXT NOT NULL DEFAULT 'PAYMENT',  -- PAYMENT | NSF | FEE | ADJUSTMENT
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_payment_source_txn UNIQUE (source_system, source_txn_id)
);

CREATE INDEX IF NOT EXISTS ix_payment_account_posted
  ON canonical.payment (account_id, posted_at DESC);

-- ---------------------------------------------------------------------------
-- canonical.service_product  (subscriptions catalog)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.service_product (
  product_sku         TEXT PRIMARY KEY,   -- BLUECRUISE_1, SXM_PREMIUM, AUTOPILOT_ENHANCED
  product_family      canonical.product_family NOT NULL,
  display_name        TEXT NOT NULL,
  billing_model       canonical.billing_model NOT NULL DEFAULT 'MONTHLY',
  is_vehicle_bound    BOOLEAN NOT NULL DEFAULT true,
  oem_feature_code    TEXT,
  active              BOOLEAN NOT NULL DEFAULT true,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- canonical.subscription
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.subscription (
  subscription_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_subscription_id TEXT NOT NULL,   -- id in subscriptions core
  party_id            UUID NOT NULL REFERENCES canonical.party (party_id),
  vehicle_id          UUID REFERENCES canonical.vehicle (vehicle_id),
  product_sku         TEXT NOT NULL REFERENCES canonical.service_product (product_sku),
  status              canonical.subscription_status NOT NULL,
  start_at            TIMESTAMPTZ,
  trial_end_at        TIMESTAMPTZ,
  current_period_end  TIMESTAMPTZ,
  cancel_at           TIMESTAMPTZ,
  price_cents         BIGINT,
  currency_code       CHAR(3) NOT NULL DEFAULT 'USD',
  sales_channel       canonical.sales_channel,
  bundled_account_id  UUID REFERENCES canonical.account (account_id),  -- F&I bundle when known
  telematics_enrollment_id TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_subscription_source UNIQUE (source_subscription_id)
);

CREATE INDEX IF NOT EXISTS ix_subscription_party
  ON canonical.subscription (party_id);
CREATE INDEX IF NOT EXISTS ix_subscription_vehicle
  ON canonical.subscription (vehicle_id);
CREATE INDEX IF NOT EXISTS ix_subscription_status
  ON canonical.subscription (status);

-- ---------------------------------------------------------------------------
-- canonical.external_identifier  (cross-core join / GraphQL passthrough keys)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.external_identifier (
  external_identifier_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_system       canonical.source_system NOT NULL,
  entity_type         canonical.external_entity_type NOT NULL,
  external_id         TEXT NOT NULL,
  -- Exactly one of the canonical FK targets should be set for POC clarity
  party_id            UUID REFERENCES canonical.party (party_id) ON DELETE CASCADE,
  account_id          UUID REFERENCES canonical.account (account_id) ON DELETE CASCADE,
  vehicle_id          UUID REFERENCES canonical.vehicle (vehicle_id) ON DELETE CASCADE,
  subscription_id     UUID REFERENCES canonical.subscription (subscription_id) ON DELETE CASCADE,
  dealer_id           UUID REFERENCES canonical.dealer (dealer_id) ON DELETE CASCADE,
  is_primary          BOOLEAN NOT NULL DEFAULT true,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_external_id UNIQUE (source_system, entity_type, external_id),
  CONSTRAINT ck_external_one_target CHECK (
    (
      (party_id IS NOT NULL)::INT +
      (account_id IS NOT NULL)::INT +
      (vehicle_id IS NOT NULL)::INT +
      (subscription_id IS NOT NULL)::INT +
      (dealer_id IS NOT NULL)::INT
    ) = 1
  )
);

CREATE INDEX IF NOT EXISTS ix_ext_party ON canonical.external_identifier (party_id);
CREATE INDEX IF NOT EXISTS ix_ext_account ON canonical.external_identifier (account_id);
CREATE INDEX IF NOT EXISTS ix_ext_vehicle ON canonical.external_identifier (vehicle_id);

-- ---------------------------------------------------------------------------
-- canonical.change_event  (agent timeline)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS canonical.change_event (
  change_event_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_system       canonical.source_system NOT NULL,
  event_type          TEXT NOT NULL,
  occurred_at         TIMESTAMPTZ NOT NULL,
  party_id            UUID REFERENCES canonical.party (party_id),
  account_id          UUID REFERENCES canonical.account (account_id),
  subscription_id     UUID REFERENCES canonical.subscription (subscription_id),
  summary             TEXT NOT NULL,
  payload             JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_change_party_time
  ON canonical.change_event (party_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_change_account_time
  ON canonical.change_event (account_id, occurred_at DESC);

-- ---------------------------------------------------------------------------
-- Source projections (faithful, re-playable) — minimal POC columns + JSONB body
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS source_legacy_recv.account_raw (
  ingest_run_id       UUID NOT NULL,
  account_number      TEXT NOT NULL,
  payload             JSONB NOT NULL,
  extracted_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (ingest_run_id, account_number)
);

CREATE TABLE IF NOT EXISTS source_modern_recv.event_raw (
  event_id            TEXT PRIMARY KEY,
  event_type          TEXT NOT NULL,
  customer_id         TEXT,
  contract_id         TEXT,
  occurred_at         TIMESTAMPTZ NOT NULL,
  payload             JSONB NOT NULL,
  ingested_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS source_subscriptions.subscription_raw (
  ingest_run_id       UUID NOT NULL,
  subscription_id     TEXT NOT NULL,
  payload             JSONB NOT NULL,
  extracted_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (ingest_run_id, subscription_id)
);

-- ---------------------------------------------------------------------------
-- ops
-- ---------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE ops.ingest_status AS ENUM (
    'STARTED', 'SUCCEEDED', 'FAILED', 'PARTIAL'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS ops.ingest_run (
  ingest_run_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_system       canonical.source_system NOT NULL,
  run_type            TEXT NOT NULL,          -- FILE_BATCH | EVENT | ETL
  business_date       DATE,
  status              ops.ingest_status NOT NULL DEFAULT 'STARTED',
  source_uri          TEXT,                  -- gs://... file or topic
  records_in          BIGINT NOT NULL DEFAULT 0,
  records_ok          BIGINT NOT NULL DEFAULT 0,
  records_quarantined BIGINT NOT NULL DEFAULT 0,
  started_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at         TIMESTAMPTZ,
  error_summary       TEXT,
  metadata            JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS ops.idempotency_key (
  source_system       canonical.source_system NOT NULL,
  idempotency_key     TEXT NOT NULL,
  first_seen_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  result_ref          TEXT,
  PRIMARY KEY (source_system, idempotency_key)
);

CREATE TABLE IF NOT EXISTS ops.outbox (
  outbox_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  aggregate_type      TEXT NOT NULL,
  aggregate_id        UUID NOT NULL,
  event_type          TEXT NOT NULL,
  payload             JSONB NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  published_at        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS ix_outbox_unpublished
  ON ops.outbox (created_at)
  WHERE published_at IS NULL;

CREATE TABLE IF NOT EXISTS ops.quarantine (
  quarantine_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ingest_run_id       UUID REFERENCES ops.ingest_run (ingest_run_id),
  source_system       canonical.source_system NOT NULL,
  reason              TEXT NOT NULL,
  payload             JSONB NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ops.access_audit (
  access_audit_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id            TEXT NOT NULL,         -- agent or customer subject
  actor_type          TEXT NOT NULL,         -- AGENT | CUSTOMER | SYSTEM
  operation           TEXT NOT NULL,         -- GraphQL operation name
  party_id            UUID,
  account_id          UUID,
  passthrough_core    canonical.source_system,
  occurred_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  metadata            JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS ix_access_audit_actor_time
  ON ops.access_audit (actor_id, occurred_at DESC);

-- ---------------------------------------------------------------------------
-- Convenience views for GraphQL / agent profile
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW canonical.v_party_servicing_profile AS
SELECT
  p.party_id,
  p.display_name,
  p.party_type,
  p.status AS party_status,
  (SELECT COUNT(*) FROM canonical.account_party_role r WHERE r.party_id = p.party_id) AS account_role_count,
  (SELECT COUNT(*) FROM canonical.subscription s
     WHERE s.party_id = p.party_id AND s.status IN ('TRIAL', 'ACTIVE', 'PAST_DUE')) AS active_subscription_count
FROM canonical.party p;

CREATE OR REPLACE VIEW canonical.v_account_current_balance AS
SELECT DISTINCT ON (b.account_id)
  b.account_id,
  b.as_of_date,
  b.principal_cents,
  b.total_amount_due_cents,
  b.payoff_cents,
  b.aging_bucket,
  b.source_system
FROM canonical.balance_snapshot b
ORDER BY b.account_id, b.as_of_date DESC, b.as_of_ts DESC;

-- ---------------------------------------------------------------------------
-- Seed catalog SKUs (POC)
-- ---------------------------------------------------------------------------
INSERT INTO canonical.service_product (product_sku, product_family, display_name, billing_model, oem_feature_code)
VALUES
  ('SXM_PREMIUM',          'MEDIA',         'SiriusXM Premier',     'MONTHLY', 'SXM_PREM'),
  ('BLUECRUISE_1',         'DRIVER_ASSIST', 'BlueCruise',           'MONTHLY', 'BC_1'),
  ('AUTOPILOT_ENHANCED',   'DRIVER_ASSIST', 'Autopilot Enhanced',   'MONTHLY', 'AP_ENH')
ON CONFLICT (product_sku) DO NOTHING;

COMMIT;

-- ---------------------------------------------------------------------------
-- Notes for application layer
-- ---------------------------------------------------------------------------
-- 1. Canonicalizer upserts party/account/subscription then writes external_identifier rows:
--      LEGACY_RECEIVABLES + ACCOUNT + account_number → account_id
--      MODERN_RECEIVABLES + PARTY + customer_id → party_id
--      MODERN_RECEIVABLES + ACCOUNT + contract_id → account_id
--      SUBSCRIPTIONS + SUBSCRIPTION + subscription_id → subscription_id
-- 2. Match keys (POC): VIN, tax_id_last4 + name, email, legacy_account_number ↔ modern external_account_number
-- 3. Do not store PAN / full tax id in this database; use tokens.
-- 4. GraphQL passthrough uses external_identifier to call the owning core for non-canonical fields.
;