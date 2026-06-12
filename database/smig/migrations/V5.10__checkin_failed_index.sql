DROP INDEX IF EXISTS uq_activity_checkin_failed;

CREATE UNIQUE INDEX IF NOT EXISTS uq_activity_checkin_failed
    ON activity (booking_id, started_at)
    WHERE event_type = 'checkin_failed';
