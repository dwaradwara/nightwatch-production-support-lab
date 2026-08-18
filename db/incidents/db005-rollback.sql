\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'tickets'
          AND column_name = 'job_state'
    ) THEN
        RAISE EXCEPTION 'DB-005 rollback requires tickets.job_state';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'tickets'
          AND column_name = 'processing_status'
    ) THEN
        RAISE EXCEPTION 'DB-005 rollback refuses to overwrite tickets.processing_status';
    END IF;
END
$$;

ALTER TABLE tickets RENAME COLUMN job_state TO processing_status;

COMMIT;
