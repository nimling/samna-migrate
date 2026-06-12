-- upgrade_to_3: down support. Adds down_proposal cache, undoing_history_id link,
-- and 'down' to the action_type CHECK and 'reverted' to the state CHECK.

CREATE TABLE IF NOT EXISTS samna_migrate.down_proposal (
    id              SERIAL PRIMARY KEY,
    file_id         INTEGER NOT NULL REFERENCES samna_migrate.file(id),
    forward_sha256  TEXT    NOT NULL,
    model           TEXT    NOT NULL,
    prompt_hash     TEXT    NOT NULL,
    proposed_sql    TEXT    NOT NULL,
    proposed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    accepted_at     TIMESTAMPTZ,
    executed_at     TIMESTAMPTZ,
    succeeded       BOOLEAN,
    error_message   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS down_proposal_file_id_idx ON samna_migrate.down_proposal(file_id);
CREATE INDEX IF NOT EXISTS down_proposal_forward_sha_idx ON samna_migrate.down_proposal(forward_sha256);

ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS undoing_history_id INTEGER REFERENCES samna_migrate.history(id);

CREATE INDEX IF NOT EXISTS history_undoing_idx ON samna_migrate.history(undoing_history_id);

ALTER TABLE samna_migrate.history DROP CONSTRAINT IF EXISTS history_action_type_check;
ALTER TABLE samna_migrate.history ADD CONSTRAINT history_action_type_check
    CHECK (action_type IN ('apply','rebaseline','rename','reorder','fold','remove',
                            'upgrade','upgrade_rebaseline','merge_apply','merge_revert',
                            'stamp','down'));

ALTER TABLE samna_migrate.file DROP CONSTRAINT IF EXISTS file_state_check;
ALTER TABLE samna_migrate.file ADD CONSTRAINT file_state_check
    CHECK (state IN ('pending','applied','folded','removed','reverted'));
