CREATE INDEX IF NOT EXISTS idx_activity_booking_ended_started
    ON activity (event_type, started_at, ended_at)
    WHERE sa_deleted_at IS NULL AND event_type = 'booking_ended';

CREATE INDEX IF NOT EXISTS idx_activity_booking_ended_bookable
    ON activity (bookable_id, started_at, ended_at)
    WHERE sa_deleted_at IS NULL AND event_type = 'booking_ended' AND bookable_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_activity_booking_ended_location
    ON activity (location_id, started_at, ended_at)
    WHERE sa_deleted_at IS NULL AND event_type = 'booking_ended' AND location_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_activity_booking_ended_organization
    ON activity (organization_id, started_at, ended_at)
    WHERE sa_deleted_at IS NULL AND event_type = 'booking_ended' AND organization_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_activity_booking_ended_bookable_type
    ON activity (bookable_type_id, started_at, ended_at)
    WHERE sa_deleted_at IS NULL AND event_type = 'booking_ended' AND bookable_type_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_activity_booking_ended_user
    ON activity (user_id, started_at, ended_at)
    WHERE sa_deleted_at IS NULL AND event_type = 'booking_ended' AND user_id IS NOT NULL;
