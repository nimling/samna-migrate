-- upgrade_to_7: allow external one-off SQL applies recorded in history without a file row.

ALTER TABLE samna_migrate.history DROP CONSTRAINT IF EXISTS history_action_type_check;
ALTER TABLE samna_migrate.history ADD CONSTRAINT history_action_type_check
    CHECK (action_type IN ('apply','external','rebaseline','rebase','rebase_undo','rename','reorder',
                            'fold','remove','upgrade','upgrade_rebaseline','merge_apply',
                            'merge_revert','stamp','down'));
