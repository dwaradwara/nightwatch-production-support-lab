CREATE TABLE IF NOT EXISTS tickets (
    id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    severity VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL
);

ALTER TABLE tickets
    ADD COLUMN IF NOT EXISTS processing_status VARCHAR(30) NOT NULL DEFAULT 'pending',
    ADD COLUMN IF NOT EXISTS customer_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS request_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS ticket_events (
    event_id UUID PRIMARY KEY,
    ticket_id INTEGER NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    event_type VARCHAR(80) NOT NULL,
    request_id VARCHAR(100),
    details JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ticket_events_ticket_id
    ON ticket_events(ticket_id);

-- Phase 6 database workload.
-- This table models a high-volume customer activity feed used for query-plan,
-- indexing, lock, transaction and connection-pool exercises. The seed is
-- deterministic so incident evidence is reproducible across CI environments.
CREATE TABLE IF NOT EXISTS customer_activity (
    id BIGSERIAL PRIMARY KEY,
    customer_id VARCHAR(32) NOT NULL,
    event_type VARCHAR(40) NOT NULL,
    payload TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL
);

INSERT INTO customer_activity (customer_id, event_type, payload, occurred_at)
SELECT
    'customer-' || LPAD((((g - 1) % 5000) + 1)::text, 4, '0'),
    CASE (g % 4)
        WHEN 0 THEN 'ticket.created'
        WHEN 1 THEN 'ticket.updated'
        WHEN 2 THEN 'notification.sent'
        ELSE 'ticket.viewed'
    END,
    REPEAT('activity-payload-', 8) || g::text,
    TIMESTAMPTZ '2026-08-01 00:00:00+00' + (g * INTERVAL '15 seconds')
FROM generate_series(1, 100000) AS g
WHERE NOT EXISTS (SELECT 1 FROM customer_activity LIMIT 1);

CREATE INDEX IF NOT EXISTS idx_customer_activity_customer_time
    ON customer_activity (customer_id, occurred_at DESC);

ANALYZE customer_activity;

-- DB-002 lock-contention fixture. The row is intentionally small and isolated
-- from ticket processing so the exercise teaches transaction blocking rather
-- than mixing lock diagnosis with the DB-001 query-plan workload.
CREATE TABLE IF NOT EXISTS customer_account_state (
    customer_id VARCHAR(32) PRIMARY KEY,
    state VARCHAR(30) NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO customer_account_state (customer_id, state)
VALUES ('customer-0042', 'Normal')
ON CONFLICT (customer_id) DO NOTHING;

INSERT INTO tickets (title, severity, status, processing_status, customer_id)
SELECT 'Customer API returning 502', 'SEV2', 'Resolved', 'seeded', 'opsforge-seed'
WHERE NOT EXISTS (SELECT 1 FROM tickets);

INSERT INTO tickets (title, severity, status, processing_status, customer_id)
SELECT 'Database latency investigation', 'SEV3', 'Investigating', 'seeded', 'opsforge-seed'
WHERE NOT EXISTS (
    SELECT 1 FROM tickets WHERE title = 'Database latency investigation'
);

INSERT INTO tickets (title, severity, status, processing_status, customer_id)
SELECT 'Worker queue processing delay', 'SEV3', 'Open', 'seeded', 'opsforge-seed'
WHERE NOT EXISTS (
    SELECT 1 FROM tickets WHERE title = 'Worker queue processing delay'
);
