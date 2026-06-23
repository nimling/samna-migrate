-- upgrade_to_5: store the deployed sql body on file and history, add rebase action types.

ALTER TABLE samna_migrate.file    ADD COLUMN IF NOT EXISTS applied_sql TEXT;
ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS applied_sql TEXT;

ALTER TABLE samna_migrate.history DROP CONSTRAINT IF EXISTS history_action_type_check;
ALTER TABLE samna_migrate.history ADD CONSTRAINT history_action_type_check
    CHECK (action_type IN ('apply','rebaseline','rebase','rebase_undo','rename','reorder',
                            'fold','remove','upgrade','upgrade_rebaseline','merge_apply',
                            'merge_revert','stamp','down'));
