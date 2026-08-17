\set ON_ERROR_STOP on

-- Phase 3 deployment compatibility gate.
-- These zero-row queries fail immediately when the running database is missing
-- a column required by the current application/worker release.
SELECT
    id,
    title,
    severity,
    status,
    processing_status,
    customer_id,
    request_id,
    created_at,
    processed_at
FROM tickets
LIMIT 0;

SELECT
    event_id,
    ticket_id,
    event_type,
    request_id,
    details,
    created_at
FROM ticket_events
LIMIT 0;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = 'ticket_events'
          AND indexname = 'idx_ticket_events_ticket_id'
    ) THEN
        RAISE EXCEPTION 'required index idx_ticket_events_ticket_id is missing';
    END IF;
END
$$;
