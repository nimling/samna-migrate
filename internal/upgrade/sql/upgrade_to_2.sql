-- upgrade_to_2: yaml sha tracking, position column, applied_* audit, guard trigger.

ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS yaml_sha256 TEXT;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS yaml_observed_at TIMESTAMPTZ;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS yaml_prior_sha256 TEXT;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS yaml_prior_observed_at TIMESTAMPTZ;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_command TEXT;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_started_at TIMESTAMPTZ;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_ended_at TIMESTAMPTZ;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_status TEXT;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_duration_ms INTEGER;

UPDATE samna_migrate.state SET last_command = last_run_command
WHERE last_command IS NULL AND last_run_command IS NOT NULL;
UPDATE samna_migrate.state SET last_ended_at = last_run_at
WHERE last_ended_at IS NULL AND last_run_at IS NOT NULL;
UPDATE samna_migrate.state SET last_status = last_run_status
WHERE last_status IS NULL AND last_run_status IS NOT NULL;

DO $body$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'samna_migrate.state'::regclass AND conname = 'state_singleton') THEN
        BEGIN
            ALTER TABLE samna_migrate.state ADD CONSTRAINT state_singleton CHECK (id = 1);
        EXCEPTION WHEN check_violation THEN
            RAISE NOTICE 'state has rows with id <> 1; skipping state_singleton';
        END;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'samna_migrate.state'::regclass AND conname = 'state_last_status_check') THEN
        ALTER TABLE samna_migrate.state ADD CONSTRAINT state_last_status_check
            CHECK (last_status IS NULL OR last_status IN ('success','failure','running'));
    END IF;
END $body$;

DO $body$ BEGIN
    BEGIN
        ALTER TABLE samna_migrate.history ALTER COLUMN step DROP NOT NULL;
    EXCEPTION WHEN undefined_column THEN NULL;
    END;
    BEGIN
        ALTER TABLE samna_migrate.history ALTER COLUMN checksum DROP NOT NULL;
    EXCEPTION WHEN undefined_column THEN NULL;
    END;
END $body$;

ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS prior_file_path TEXT;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS renamed_at TIMESTAMPTZ;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS position INTEGER;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS position_prior INTEGER;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS position_changed_at TIMESTAMPTZ;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS state_changed_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS applied_at TIMESTAMPTZ;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS applied_history_id INTEGER REFERENCES samna_migrate.history(id);
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS applied_sha256 TEXT;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS applied_position INTEGER;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS attempt_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS last_attempt_at TIMESTAMPTZ;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS last_attempt_history_id INTEGER REFERENCES samna_migrate.history(id);
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS drift_at TIMESTAMPTZ;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS drift_sha256 TEXT;
ALTER TABLE samna_migrate.file ADD COLUMN IF NOT EXISTS removed_at TIMESTAMPTZ;

UPDATE samna_migrate.file SET applied_at         = last_applied_at         WHERE applied_at IS NULL         AND last_applied_at IS NOT NULL;
UPDATE samna_migrate.file SET applied_history_id = last_applied_history_id WHERE applied_history_id IS NULL AND last_applied_history_id IS NOT NULL;
UPDATE samna_migrate.file SET attempt_count      = attempts_count          WHERE attempt_count = 0          AND attempts_count > 0;
UPDATE samna_migrate.file SET drift_at           = last_drift_at           WHERE drift_at IS NULL           AND last_drift_at IS NOT NULL;
UPDATE samna_migrate.file SET drift_sha256       = last_drift_sha256       WHERE drift_sha256 IS NULL       AND last_drift_sha256 IS NOT NULL;
UPDATE samna_migrate.file SET removed_at         = removed_from_disk_at    WHERE removed_at IS NULL         AND removed_from_disk_at IS NOT NULL;
UPDATE samna_migrate.file SET applied_sha256     = sha256                  WHERE applied_sha256 IS NULL     AND state = 'applied';
UPDATE samna_migrate.file SET last_attempt_at    = applied_at              WHERE last_attempt_at IS NULL    AND applied_at IS NOT NULL;

UPDATE samna_migrate.file f
SET applied_history_id = sub.history_id,
    applied_at         = COALESCE(f.applied_at, sub.applied_at)
FROM (
    SELECT DISTINCT ON (file_path) file_path, id AS history_id, applied_at
    FROM samna_migrate.history
    WHERE success = true AND file_path IS NOT NULL AND action_type = 'apply'
    ORDER BY file_path, applied_at DESC, id DESC
) sub
WHERE f.applied_history_id IS NULL
  AND f.state            = 'applied'
  AND f.file_path        = sub.file_path;

WITH ordered AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS pos FROM samna_migrate.file
)
UPDATE samna_migrate.file f SET position = o.pos
FROM ordered o WHERE f.id = o.id AND f.position IS NULL;

UPDATE samna_migrate.file SET applied_position = position
WHERE applied_position IS NULL AND state = 'applied';

ALTER TABLE samna_migrate.file ALTER COLUMN position SET NOT NULL;

DO $body$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'samna_migrate.file'::regclass AND conname = 'file_position_unique') THEN
        ALTER TABLE samna_migrate.file ADD CONSTRAINT file_position_unique UNIQUE (position) DEFERRABLE INITIALLY DEFERRED;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'samna_migrate.file'::regclass AND conname = 'file_applied_consistent') THEN
        ALTER TABLE samna_migrate.file ADD CONSTRAINT file_applied_consistent
            CHECK (state <> 'applied' OR applied_at IS NOT NULL);
    END IF;
END $body$;

ALTER TABLE samna_migrate.file DROP CONSTRAINT IF EXISTS file_state_check;
ALTER TABLE samna_migrate.file ADD CONSTRAINT file_state_check
    CHECK (state IN ('pending','applied','folded','removed'));

ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS yaml_sha256 TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS position INTEGER;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS started_at TIMESTAMPTZ;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS ended_at TIMESTAMPTZ;

UPDATE samna_migrate.history SET ended_at = applied_at WHERE ended_at IS NULL;
UPDATE samna_migrate.history SET started_at = applied_at - (duration_ms || ' milliseconds')::interval WHERE started_at IS NULL;

DO $body$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'samna_migrate.history'::regclass AND conname = 'history_action_type_check') THEN
        ALTER TABLE samna_migrate.history ADD CONSTRAINT history_action_type_check
            CHECK (action_type IN ('apply','rebaseline','rename','reorder','fold','remove','upgrade','upgrade_rebaseline','merge_apply','merge_revert','stamp'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'samna_migrate.history'::regclass AND conname = 'history_success_no_error') THEN
        ALTER TABLE samna_migrate.history ADD CONSTRAINT history_success_no_error
            CHECK (success = false OR error_sqlstate IS NULL);
    END IF;
END $body$;

CREATE OR REPLACE FUNCTION samna_migrate.guard_mutation()
RETURNS TRIGGER AS $body$
BEGIN
    IF coalesce(current_setting('samna_migrate.upgrade_mode', TRUE), 'false') = 'true' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    IF TG_TABLE_NAME = 'history' THEN
        RAISE EXCEPTION 'samna_migrate.history is append only outside upgrade mode';
    END IF;
    IF TG_TABLE_NAME = 'file' THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'samna_migrate.file is not deletable outside upgrade mode';
        END IF;
        IF NEW.position IS DISTINCT FROM OLD.position THEN RAISE EXCEPTION 'samna_migrate.file.position is upgrade only'; END IF;
        IF NEW.sha256 IS DISTINCT FROM OLD.sha256 THEN RAISE EXCEPTION 'samna_migrate.file.sha256 is upgrade only'; END IF;
        IF NEW.file_path IS DISTINCT FROM OLD.file_path THEN RAISE EXCEPTION 'samna_migrate.file.file_path is upgrade only'; END IF;
        IF NEW.slug IS DISTINCT FROM OLD.slug THEN RAISE EXCEPTION 'samna_migrate.file.slug is upgrade only'; END IF;
    END IF;
    RETURN NEW;
END;
$body$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS history_guard ON samna_migrate.history;
CREATE TRIGGER history_guard BEFORE UPDATE OR DELETE ON samna_migrate.history
    FOR EACH ROW EXECUTE FUNCTION samna_migrate.guard_mutation();

DROP TRIGGER IF EXISTS file_guard ON samna_migrate.file;
CREATE TRIGGER file_guard BEFORE UPDATE OR DELETE ON samna_migrate.file
    FOR EACH ROW EXECUTE FUNCTION samna_migrate.guard_mutation();

CREATE INDEX IF NOT EXISTS file_position_idx       ON samna_migrate.file(position);
CREATE INDEX IF NOT EXISTS file_step_type_idx      ON samna_migrate.file(step_type);
CREATE INDEX IF NOT EXISTS history_started_at_idx  ON samna_migrate.history(started_at DESC);
CREATE INDEX IF NOT EXISTS history_action_type_idx ON samna_migrate.history(action_type);
