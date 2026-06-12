-- upgrade_to_1: establish samna_migrate.state, samna_migrate.history, samna_migrate.file.

ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS schema_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS tool_version TEXT;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_run_at TIMESTAMPTZ;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_run_status TEXT;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_run_command TEXT;
ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_run_duration_ms INTEGER;

CREATE TABLE IF NOT EXISTS samna_migrate.history (
    id SERIAL PRIMARY KEY,
    step_name TEXT,
    file_path TEXT NOT NULL,
    sha256 TEXT,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    duration_ms INTEGER NOT NULL DEFAULT 0,
    success BOOLEAN NOT NULL DEFAULT true
);

ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS file_id INTEGER;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS step_type TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS slug TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS version TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS file_name TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS size_bytes INTEGER;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS attempt INTEGER NOT NULL DEFAULT 1;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS action_type TEXT NOT NULL DEFAULT 'apply';
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS tool_version TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS executed_by TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS host TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS database TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS error_sqlstate TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS error_message TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS notes TEXT;

CREATE TABLE IF NOT EXISTS samna_migrate.file (
    id SERIAL PRIMARY KEY,
    step_name TEXT NOT NULL,
    step_type TEXT NOT NULL,
    slug TEXT NOT NULL,
    version TEXT,
    file_name TEXT NOT NULL,
    file_path TEXT NOT NULL UNIQUE,
    sha256 TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending','applied','folded')),
    first_seen TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    discovered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_applied_at TIMESTAMPTZ,
    last_applied_history_id INTEGER,
    last_attempt_status TEXT,
    attempts_count INTEGER NOT NULL DEFAULT 0,
    last_drift_sha256 TEXT,
    last_drift_at TIMESTAMPTZ,
    folded_at TIMESTAMPTZ,
    folded_into TEXT,
    removed_from_disk_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS history_file_id_idx     ON samna_migrate.history(file_id);
CREATE INDEX IF NOT EXISTS history_applied_at_idx  ON samna_migrate.history(applied_at DESC);
CREATE INDEX IF NOT EXISTS file_state_idx          ON samna_migrate.file(state);
CREATE INDEX IF NOT EXISTS file_slug_idx           ON samna_migrate.file(slug);
