-- V1__init_schema.sql
-- PinGo: initial schema (PostgreSQL 15+, Flyway migration)
--
-- Conventions
--  * Every tenant-owned table carries tenant_id.
--  * References between tenant-owned tables use composite FKs (tenant_id, id),
--    so the database itself refuses cross-tenant references.
--  * Money is stored in cents (bigint). Timestamps are timestamptz (UTC).
--  * Status columns are varchar + CHECK (friendlier to Flyway/JPA than native enums).
--  * gen_random_uuid() is built into PostgreSQL 13+.
--  * Sensitive identifiers (CPF/CNPJ) are encrypted by the application (AES-256-GCM)
--    and searched through a blind index (HMAC-SHA256). The database never sees the
--    plain document, nor the keys. key_version allows key rotation.
--  * Row Level Security (RLS) is the 4th tenant-isolation layer (after the JWT claim,
--    the repository filter and the composite FKs). The application sets, per transaction:
--      SELECT set_config('app.tenant_id', '<uuid>', true);   -- normal requests
--      SELECT set_config('app.scope', 'system', true);       -- login, webhook, public page, workers
--    The application must connect with a role that is NOT a superuser (superusers
--    bypass RLS). See the RLS block at the end of this file.
--  * This migration has not been applied anywhere yet, so it is still safe to edit.
--    After the first real deploy, never edit it: create V2+ (fix-forward).

-- =====================================================================
-- Tenants, users and access
-- =====================================================================

CREATE TABLE tenants (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name                  varchar(150) NOT NULL,
    document_enc          bytea,                             -- CNPJ/CPF (digits only) encrypted: nonce || ciphertext || tag
    document_idx          char(64),                          -- HMAC-SHA256 hex (blind index) for uniqueness and lookup
    key_version           smallint,                          -- version of the encryption/blind-index keys
    timezone             varchar(50)  NOT NULL DEFAULT 'America/Sao_Paulo',
    status                varchar(20)  NOT NULL DEFAULT 'ACTIVE'
                              CHECK (status IN ('ACTIVE', 'SUSPENDED')),
    rate_limit_per_minute integer      NOT NULL DEFAULT 120 CHECK (rate_limit_per_minute > 0),
    send_window_start     time         NOT NULL DEFAULT '08:00',
    send_window_end       time         NOT NULL DEFAULT '20:00',
    created_at            timestamptz  NOT NULL DEFAULT now(),
    updated_at            timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT ck_tenants_window CHECK (send_window_start < send_window_end),
    CONSTRAINT ck_tenants_document CHECK (
        (document_enc IS NULL AND document_idx IS NULL AND key_version IS NULL)
        OR (document_enc IS NOT NULL AND document_idx IS NOT NULL AND key_version IS NOT NULL))
);

CREATE UNIQUE INDEX uq_tenants_document ON tenants (document_idx) WHERE document_idx IS NOT NULL;

CREATE TABLE users (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid         NOT NULL REFERENCES tenants (id),
    name          varchar(150) NOT NULL,
    email         varchar(254) NOT NULL,
    -- Argon2id through Spring's DelegatingPasswordEncoder: "{argon2@SpringSecurity_v5_8}$argon2id$v=19$m=...".
    -- About 125 chars today; 255 leaves room for stronger parameters or another algorithm.
    password_hash varchar(255) NOT NULL,
    password_changed_at timestamptz,
    role          varchar(20)  NOT NULL CHECK (role IN ('ADMIN', 'OPERATOR')),
    active        boolean      NOT NULL DEFAULT true,
    email_verified_at timestamptz,                           -- null = not verified yet
    failed_login_attempts integer NOT NULL DEFAULT 0 CHECK (failed_login_attempts >= 0),
    locked_until  timestamptz,                               -- progressive lockout after repeated failures
    last_login_at timestamptz,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now()
);

-- Login does not ask for the tenant, so e-mail is unique across the whole system.
CREATE UNIQUE INDEX uq_users_email ON users (lower(email));
CREATE INDEX idx_users_tenant ON users (tenant_id);

CREATE TABLE refresh_tokens (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    family_id  uuid        NOT NULL,                         -- rotation family (reuse detection)
    token_hash char(64)    NOT NULL UNIQUE,                  -- SHA-256 hex
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_refresh_tokens_user   ON refresh_tokens (user_id);
CREATE INDEX idx_refresh_tokens_family ON refresh_tokens (family_id);

-- One-time tokens sent by e-mail: password reset and e-mail verification.
-- Only the SHA-256 of the token is stored; the token itself travels in the e-mail link.
CREATE TABLE user_tokens (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    purpose    varchar(30) NOT NULL CHECK (purpose IN ('PASSWORD_RESET', 'EMAIL_VERIFICATION')),
    token_hash char(64)    NOT NULL UNIQUE,                  -- SHA-256 hex
    expires_at timestamptz NOT NULL,                         -- reset: 30 min; verification: 24 h
    used_at    timestamptz,                                  -- single use
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_user_tokens_user ON user_tokens (user_id, purpose);

CREATE TABLE api_keys (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid         NOT NULL REFERENCES tenants (id),
    name         varchar(100) NOT NULL,
    key_prefix   varchar(12)  NOT NULL,                      -- visible part, e.g. "pk_live_ab12"
    key_hash     char(64)     NOT NULL UNIQUE,               -- SHA-256 hex of the full key
    last_used_at timestamptz,
    revoked_at   timestamptz,
    created_at   timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX idx_api_keys_tenant ON api_keys (tenant_id);

-- =====================================================================
-- PSP accounts (references to secrets only, never the secrets themselves)
-- =====================================================================

CREATE TABLE psp_accounts (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),   -- used in the webhook URL
    tenant_id          uuid         NOT NULL REFERENCES tenants (id),
    provider           varchar(20)  NOT NULL CHECK (provider IN ('ASAAS', 'STRIPE', 'MOCK')),
    environment        varchar(10)  NOT NULL CHECK (environment IN ('SANDBOX', 'PRODUCTION')),
    credentials_ref    varchar(200) NOT NULL,                        -- e.g. Secrets Manager name (Stripe secret key)
    webhook_secret_ref varchar(200) NOT NULL,                        -- Stripe webhook signing secret (whsec_...)
    webhook_secret_previous_ref varchar(200),                        -- old secret, still accepted during rotation
    external_account_id varchar(100),                                -- Stripe connected account (acct_...); null when using the platform's own account
    active             boolean      NOT NULL DEFAULT true,
    created_at         timestamptz  NOT NULL DEFAULT now(),
    updated_at         timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id)
);

CREATE UNIQUE INDEX uq_psp_accounts_active
    ON psp_accounts (tenant_id, provider, environment) WHERE active;

-- =====================================================================
-- Customers (debtors)
-- =====================================================================

CREATE TABLE customers (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid         NOT NULL REFERENCES tenants (id),
    name          varchar(150) NOT NULL,
    document_enc  bytea,                                     -- CPF/CNPJ (digits only) encrypted: nonce || ciphertext || tag
    document_idx  char(64),                                  -- HMAC-SHA256 hex (blind index), per-tenant uniqueness
    key_version   smallint,                                  -- version of the encryption/blind-index keys
    email         varchar(254),
    phone         varchar(20),                               -- E.164
    email_opt_out boolean      NOT NULL DEFAULT false,
    sms_opt_out   boolean      NOT NULL DEFAULT false,
    deleted_at    timestamptz,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT ck_customers_contact CHECK (email IS NOT NULL OR phone IS NOT NULL),
    CONSTRAINT ck_customers_document CHECK (
        (document_enc IS NULL AND document_idx IS NULL AND key_version IS NULL)
        OR (document_enc IS NOT NULL AND document_idx IS NOT NULL AND key_version IS NOT NULL))
);

CREATE UNIQUE INDEX uq_customers_tenant_document
    ON customers (tenant_id, document_idx) WHERE document_idx IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX idx_customers_tenant_name ON customers (tenant_id, lower(name));

-- =====================================================================
-- Message templates and dunning policies (reminder schedule)
-- =====================================================================

CREATE TABLE message_templates (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid         NOT NULL REFERENCES tenants (id),
    name       varchar(100) NOT NULL,
    channel    varchar(10)  NOT NULL CHECK (channel IN ('EMAIL', 'SMS')),
    subject    varchar(200),
    body       text         NOT NULL,
    created_at timestamptz  NOT NULL DEFAULT now(),
    updated_at timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, id, channel),                         -- lets steps enforce channel match
    UNIQUE (tenant_id, name),
    CONSTRAINT ck_templates_subject CHECK (channel <> 'EMAIL' OR subject IS NOT NULL)
);

CREATE TABLE dunning_policies (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid         NOT NULL REFERENCES tenants (id),
    name       varchar(100) NOT NULL,
    is_default boolean      NOT NULL DEFAULT false,
    active     boolean      NOT NULL DEFAULT true,
    created_at timestamptz  NOT NULL DEFAULT now(),
    updated_at timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, name)
);

-- At most one default policy per tenant.
CREATE UNIQUE INDEX uq_dunning_policies_default ON dunning_policies (tenant_id) WHERE is_default;

CREATE TABLE dunning_steps (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid        NOT NULL,
    policy_id   uuid        NOT NULL,
    offset_days integer     NOT NULL CHECK (offset_days BETWEEN -30 AND 90),  -- negative = before due date
    channel     varchar(10) NOT NULL CHECK (channel IN ('EMAIL', 'SMS')),
    template_id uuid        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    UNIQUE (policy_id, offset_days, channel),
    FOREIGN KEY (tenant_id, policy_id)
        REFERENCES dunning_policies (tenant_id, id) ON DELETE CASCADE,
    -- Template must belong to the same tenant AND have the same channel as the step.
    FOREIGN KEY (tenant_id, template_id, channel)
        REFERENCES message_templates (tenant_id, id, channel)
);

-- =====================================================================
-- Charges
-- =====================================================================

CREATE TABLE charges (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid         NOT NULL REFERENCES tenants (id),
    customer_id         uuid         NOT NULL,
    dunning_policy_id   uuid,
    psp_account_id      uuid         NOT NULL,
    external_reference  varchar(100),                        -- tenant's own reference
    description         varchar(255) NOT NULL,
    amount_cents        bigint       NOT NULL CHECK (amount_cents > 0),
    currency            char(3)      NOT NULL DEFAULT 'BRL' CHECK (currency = 'BRL'),
    due_date            date         NOT NULL,               -- date in the tenant's timezone
    status              varchar(20)  NOT NULL DEFAULT 'PENDING'
                            CHECK (status IN ('PENDING', 'OVERDUE', 'PAID', 'CANCELED')),
    -- Pix is generated on demand (first visit to the public link), so these stay null until then.
    psp_charge_id       varchar(100),                        -- current PSP payment id (e.g. Stripe pi_...)
    pix_attempt         smallint     NOT NULL DEFAULT 0,     -- part of the PSP idempotency key: charge:{id}:pix:{attempt}
    pix_copy_paste      text,
    pix_qr_image_url    text,
    pix_expires_at      timestamptz,
    public_token        varchar(64)  NOT NULL UNIQUE         -- 32 random bytes (SecureRandom), base64url = 43 chars
                            CHECK (length(public_token) >= 43),
                                                             -- stored as is: the worker renders {{pay_link}} later
    paid_at             timestamptz,
    paid_amount_cents   bigint,
    canceled_at         timestamptz,
    cancel_reason       varchar(255),
    version             bigint       NOT NULL DEFAULT 0,     -- optimistic locking
    created_at          timestamptz  NOT NULL DEFAULT now(),
    updated_at          timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, customer_id)       REFERENCES customers (tenant_id, id),
    FOREIGN KEY (tenant_id, dunning_policy_id) REFERENCES dunning_policies (tenant_id, id),
    FOREIGN KEY (tenant_id, psp_account_id)    REFERENCES psp_accounts (tenant_id, id),
    CONSTRAINT ck_charges_paid     CHECK ((status = 'PAID')     = (paid_at IS NOT NULL)),
    CONSTRAINT ck_charges_canceled CHECK ((status = 'CANCELED') = (canceled_at IS NOT NULL))
);

CREATE UNIQUE INDEX uq_charges_external_reference
    ON charges (tenant_id, external_reference) WHERE external_reference IS NOT NULL;
CREATE UNIQUE INDEX uq_charges_psp_charge
    ON charges (psp_account_id, psp_charge_id) WHERE psp_charge_id IS NOT NULL;
CREATE INDEX idx_charges_tenant_status_due ON charges (tenant_id, status, due_date);
CREATE INDEX idx_charges_tenant_customer   ON charges (tenant_id, customer_id);
-- Feeds the daily "PENDING -> OVERDUE" job.
CREATE INDEX idx_charges_pending_due       ON charges (due_date) WHERE status = 'PENDING';

-- =====================================================================
-- Webhook inbox (idempotency) and status history
-- =====================================================================

CREATE TABLE payment_events (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid         NOT NULL,
    psp_account_id    uuid         NOT NULL,
    provider_event_id varchar(100) NOT NULL,                 -- event id sent by the PSP
    event_type        varchar(60)  NOT NULL,
    psp_charge_id     varchar(100),
    payload           jsonb        NOT NULL,
    status            varchar(20)  NOT NULL DEFAULT 'RECEIVED'
                          CHECK (status IN ('RECEIVED', 'PROCESSED', 'IGNORED', 'FAILED')),
    status_reason     varchar(255),
    attempts          integer      NOT NULL DEFAULT 0,
    received_at       timestamptz  NOT NULL DEFAULT now(),
    processed_at      timestamptz,
    UNIQUE (psp_account_id, provider_event_id),              -- the idempotency guarantee
    UNIQUE (id, tenant_id),
    FOREIGN KEY (tenant_id, psp_account_id) REFERENCES psp_accounts (tenant_id, id)
);

CREATE INDEX idx_payment_events_pending ON payment_events (received_at) WHERE status = 'RECEIVED';
CREATE INDEX idx_payment_events_charge  ON payment_events (psp_account_id, psp_charge_id);

CREATE TABLE charge_status_history (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        uuid        NOT NULL,
    charge_id        uuid        NOT NULL,
    from_status      varchar(20),
    to_status        varchar(20) NOT NULL,
    source           varchar(20) NOT NULL CHECK (source IN ('API', 'WEBHOOK', 'SCHEDULER', 'USER')),
    reason           varchar(255),
    payment_event_id uuid REFERENCES payment_events (id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, charge_id) REFERENCES charges (tenant_id, id)
);

CREATE INDEX idx_charge_history_charge ON charge_status_history (charge_id, created_at);

-- =====================================================================
-- Reminders and notifications
-- =====================================================================

CREATE TABLE scheduled_reminders (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            uuid        NOT NULL,
    charge_id            uuid        NOT NULL,
    step_id              uuid        NOT NULL,
    scheduled_for        timestamptz NOT NULL,
    status               varchar(20) NOT NULL DEFAULT 'SCHEDULED'
                             CHECK (status IN ('SCHEDULED', 'DISPATCHED', 'CANCELED', 'SKIPPED')),
    external_schedule_id varchar(200),                       -- EventBridge Scheduler id (AWS)
    dispatched_at        timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    UNIQUE (charge_id, step_id),
    FOREIGN KEY (tenant_id, charge_id) REFERENCES charges (tenant_id, id),
    FOREIGN KEY (tenant_id, step_id)   REFERENCES dunning_steps (tenant_id, id)
);

-- Feeds the poller (local) without scanning the whole table.
CREATE INDEX idx_reminders_due ON scheduled_reminders (scheduled_for) WHERE status = 'SCHEDULED';
CREATE INDEX idx_reminders_charge ON scheduled_reminders (charge_id);

CREATE TABLE notifications (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid         NOT NULL,
    charge_id           uuid         NOT NULL,
    customer_id         uuid         NOT NULL,
    reminder_id         uuid,                                -- null for manual resends
    channel             varchar(10)  NOT NULL CHECK (channel IN ('EMAIL', 'SMS')),
    recipient           varchar(254) NOT NULL,
    subject             varchar(200),
    body                text         NOT NULL,               -- rendered snapshot
    status              varchar(20)  NOT NULL DEFAULT 'QUEUED'
                            CHECK (status IN ('QUEUED', 'SENDING', 'SENT', 'FAILED', 'DEAD', 'SKIPPED')),
    status_reason       varchar(100),                        -- e.g. opt_out, charge_closed, no_contact
    attempts            integer      NOT NULL DEFAULT 0,
    next_attempt_at     timestamptz,
    provider_message_id varchar(200),
    last_error          varchar(500),
    sent_at             timestamptz,
    created_at          timestamptz  NOT NULL DEFAULT now(),
    updated_at          timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (reminder_id),                                    -- at most one notification per reminder
    FOREIGN KEY (tenant_id, charge_id)   REFERENCES charges (tenant_id, id),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id),
    FOREIGN KEY (tenant_id, reminder_id) REFERENCES scheduled_reminders (tenant_id, id)
);

CREATE INDEX idx_notifications_charge ON notifications (tenant_id, charge_id);
CREATE INDEX idx_notifications_retry  ON notifications (next_attempt_at)
    WHERE status IN ('QUEUED', 'FAILED');

-- =====================================================================
-- API idempotency and transactional outbox
-- =====================================================================

CREATE TABLE idempotency_keys (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid         NOT NULL REFERENCES tenants (id),
    idempotency_key varchar(100) NOT NULL,
    request_hash    char(64)     NOT NULL,                   -- SHA-256 of method + path + body
    response_status integer,
    response_body   jsonb,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    expires_at      timestamptz  NOT NULL,
    UNIQUE (tenant_id, idempotency_key)
);

CREATE INDEX idx_idempotency_expires ON idempotency_keys (expires_at);

CREATE TABLE outbox_events (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid         NOT NULL,
    aggregate_type varchar(50)  NOT NULL,
    aggregate_id   uuid         NOT NULL,
    event_type     varchar(80)  NOT NULL,
    payload        jsonb        NOT NULL,
    attempts       integer      NOT NULL DEFAULT 0,
    created_at     timestamptz  NOT NULL DEFAULT now(),
    published_at   timestamptz
);

-- Publisher reads only what is still unpublished.
CREATE INDEX idx_outbox_unpublished ON outbox_events (created_at) WHERE published_at IS NULL;

-- =====================================================================
-- Audit log (append-only)
-- =====================================================================
-- Who did what inside a tenant: key created/revoked, charge canceled, policy changed,
-- user created/deactivated, PSP account changed, password reset completed.
-- Never store secrets or PII in details.

CREATE TABLE audit_log (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     uuid        NOT NULL REFERENCES tenants (id),
    actor_type    varchar(10) NOT NULL CHECK (actor_type IN ('USER', 'API_KEY', 'SYSTEM')),
    actor_id      uuid,                                      -- user id or api key id (null for SYSTEM)
    action        varchar(60) NOT NULL,                      -- e.g. CHARGE_CANCELED, API_KEY_CREATED
    resource_type varchar(40),
    resource_id   uuid,
    ip_address    inet,
    details       jsonb,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_tenant_created  ON audit_log (tenant_id, created_at DESC);
CREATE INDEX idx_audit_tenant_resource ON audit_log (tenant_id, resource_type, resource_id);

CREATE FUNCTION forbid_audit_mutation() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is append-only';
END;
$$;

CREATE TRIGGER trg_audit_log_immutable
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION forbid_audit_mutation();

-- =====================================================================
-- Row Level Security (4th layer of tenant isolation)
-- =====================================================================
-- A row is visible/writable when its tenant_id equals app.tenant_id (set per transaction by
-- the application) or when the transaction runs in the explicit 'system' scope (login lookup,
-- webhook, public payment page, scheduler/workers). FORCE makes the policy apply to the table
-- owner too; superusers still bypass it, so the app must not connect as a superuser.
-- Not covered on purpose: refresh_tokens and user_tokens (no tenant_id; reached only from the
-- auth flows, always through a user id).
-- Future data migrations that touch these tables must set app.scope = 'system' first.

CREATE FUNCTION app_tenant_id() RETURNS uuid
    LANGUAGE sql STABLE AS
$$ SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid $$;

CREATE FUNCTION app_is_system() RETURNS boolean
    LANGUAGE sql STABLE AS
$$ SELECT coalesce(current_setting('app.scope', true), '') = 'system' $$;

-- tenants is keyed by id, not tenant_id.
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON tenants
    USING (id = app_tenant_id() OR app_is_system())
    WITH CHECK (id = app_tenant_id() OR app_is_system());

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'users', 'api_keys', 'psp_accounts', 'customers', 'message_templates',
        'dunning_policies', 'dunning_steps', 'charges', 'payment_events',
        'charge_status_history', 'scheduled_reminders', 'notifications',
        'idempotency_keys', 'outbox_events', 'audit_log'
    ]
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON %I '
            'USING (tenant_id = app_tenant_id() OR app_is_system()) '
            'WITH CHECK (tenant_id = app_tenant_id() OR app_is_system())', t);
    END LOOP;
END;
$$;

-- =====================================================================
-- Least-privilege grants for the application role
-- =====================================================================
-- The role is created outside Flyway (docker-compose init script / infra), because roles are
-- cluster-level objects. If it does not exist (e.g. a throwaway test database), this is a no-op.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pingo_app') THEN
        GRANT USAGE ON SCHEMA public TO pingo_app;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO pingo_app;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO pingo_app;
        REVOKE UPDATE, DELETE ON audit_log FROM pingo_app;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO pingo_app;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
            GRANT USAGE, SELECT ON SEQUENCES TO pingo_app;
    END IF;
END;
$$;
