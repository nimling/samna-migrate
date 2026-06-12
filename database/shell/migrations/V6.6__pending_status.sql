ALTER TABLE booking
    ALTER COLUMN status SET DEFAULT 'pending';

UPDATE booking
SET status = 'pending'
WHERE status = 'reserved';

ALTER TABLE object_checkin
    ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'pending';

UPDATE object_checkin
SET status = 'confirmed'
WHERE checkin_at IS NOT NULL
  AND status = 'pending';

CREATE INDEX IF NOT EXISTS idx_object_checkin_status ON object_checkin (status) WHERE sa_deleted_at IS NULL;

ALTER TABLE event_queue
    ALTER COLUMN activity_id DROP NOT NULL;
