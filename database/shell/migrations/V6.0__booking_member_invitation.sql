ALTER TABLE object_member
    ADD COLUMN IF NOT EXISTS external_id TEXT,
    ADD COLUMN IF NOT EXISTS email       TEXT,
    ADD COLUMN IF NOT EXISTS status      TEXT NOT NULL DEFAULT 'pending';

ALTER TABLE object_member
    ALTER COLUMN user_id DROP NOT NULL;

UPDATE object_member
SET status = 'accepted'
WHERE user_id IS NOT NULL
  AND status = 'pending';

ALTER TABLE object_member
    DROP CONSTRAINT IF EXISTS object_member_status_check;

ALTER TABLE object_member
    ADD CONSTRAINT object_member_status_check
    CHECK (status IN ('pending', 'accepted', 'declined'));

ALTER TABLE object_member
    DROP CONSTRAINT IF EXISTS object_member_identity_present;

ALTER TABLE object_member
    ADD CONSTRAINT object_member_identity_present
    CHECK (
        user_id     IS NOT NULL
        OR email       IS NOT NULL
        OR external_id IS NOT NULL
    );

ALTER TABLE object_member
    DROP CONSTRAINT IF EXISTS object_member_accepted_requires_user;

ALTER TABLE object_member
    ADD CONSTRAINT object_member_accepted_requires_user
    CHECK (status <> 'accepted' OR user_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_object_member_status
    ON object_member (status)
    WHERE sa_deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_object_member_email
    ON object_member (lower(email))
    WHERE email IS NOT NULL AND sa_deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_object_member_external_id
    ON object_member (external_id)
    WHERE external_id IS NOT NULL AND sa_deleted_at IS NULL;

COMMENT ON COLUMN object_member.external_id IS 'External identifier supplied by the inviter; resolves to a user_id at write time, otherwise retained for downstream sync.';
COMMENT ON COLUMN object_member.email       IS 'Email supplied by the inviter; resolves to an existing user_id at write time, otherwise retained so the invitation notification can be addressed.';
COMMENT ON COLUMN object_member.status      IS 'Lifecycle of the membership: pending while the invitee has not yet logged in and bound a user_id, accepted once a real user_id is connected, declined when the invitee opts out.';
