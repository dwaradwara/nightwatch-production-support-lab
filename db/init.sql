CREATE TABLE IF NOT EXISTS tickets (
    id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    severity VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL
);

ALTER TABLE tickets
    ADD COLUMN IF NOT EXISTS processing_status VARCHAR(30) NOT NULL DEFAULT 'pending',
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

INSERT INTO tickets (title, severity, status, processing_status)
SELECT 'Customer API returning 502', 'SEV2', 'Resolved', 'seeded'
WHERE NOT EXISTS (SELECT 1 FROM tickets);

INSERT INTO tickets (title, severity, status, processing_status)
SELECT 'Database latency investigation', 'SEV3', 'Investigating', 'seeded'
WHERE NOT EXISTS (
    SELECT 1 FROM tickets WHERE title = 'Database latency investigation'
);

INSERT INTO tickets (title, severity, status, processing_status)
SELECT 'Worker queue processing delay', 'SEV3', 'Open', 'seeded'
WHERE NOT EXISTS (
    SELECT 1 FROM tickets WHERE title = 'Worker queue processing delay'
);
