ALTER TABLE claimius.user_relation
    ADD COLUMN IF NOT EXISTS parent_id UUID REFERENCES claimius.user_relation(id),
    ADD COLUMN IF NOT EXISTS sibling_id UUID REFERENCES claimius.user_relation(id);

CREATE INDEX IF NOT EXISTS idx_user_relation_parent_id ON claimius.user_relation (parent_id);
CREATE INDEX IF NOT EXISTS idx_user_relation_sibling_id ON claimius.user_relation (sibling_id);
