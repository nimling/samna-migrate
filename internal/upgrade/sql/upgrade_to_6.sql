-- upgrade_to_6: record the git commit each file was deployed from.

ALTER TABLE samna_migrate.file    ADD COLUMN IF NOT EXISTS applied_commit TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS applied_commit TEXT;
