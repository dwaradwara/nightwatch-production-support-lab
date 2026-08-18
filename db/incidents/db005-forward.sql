\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'tickets'
          AND column_name = 'processing_status'
    ) THEN
        RAISE EXCEPTION 'DB-005 forward migration requires tickets.processing_status';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'tickets'
          AND column_name = 'job_state'
    ) THEN
        RAISE EXCEPTION 'DB-005 forward migration refuses to overwrite tickets.job_state';
    END IF;
END
$$;

-- Intentionally backward-incompatible with the currently deployed NIGHTWATCH
-- API/worker release. The data is preserved; only the column contract changes.
ALTER TABLE tickets RENAME COLUMN processing_status TO job_state;

COMMIT;
