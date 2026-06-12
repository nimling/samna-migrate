CREATE TABLE IF NOT EXISTS object_member (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    object_id       UUID NOT NULL,
    object_type     TEXT NOT NULL,
    user_id         UUID NOT NULL,
    origin_id       UUID DEFAULT NULL,
    origin_type     TEXT DEFAULT NULL,
    claim_id        UUID DEFAULT NULL REFERENCES claimius.claim(id),
    style           JSONB,
    sa_owner_id     UUID NOT NULL,
    sa_created_at   TIMESTAMPTZ NOT NULL DEFAULT current_timestamp,
    sa_updated_at   TIMESTAMPTZ NOT NULL DEFAULT current_timestamp,
    sa_deleted_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_object_member_object
    ON object_member (object_type, object_id)
    WHERE sa_deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_object_member_user
    ON object_member (user_id)
    WHERE sa_deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_object_member_origin
    ON object_member (origin_type, origin_id)
    WHERE sa_deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_object_member_claim
    ON object_member (claim_id)
    WHERE sa_deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_object_member_owner
    ON object_member (sa_owner_id)
    WHERE sa_deleted_at IS NULL;
