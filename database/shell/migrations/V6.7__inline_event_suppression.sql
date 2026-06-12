CREATE OR REPLACE FUNCTION enqueue_activity_consumers()
RETURNS TRIGGER AS $$
DECLARE
    v_payload jsonb;
BEGIN
    IF NEW.event_type IN ('booking_updated', 'booking_canceled', 'booking_deleted', 'code_scanned') THEN
        RETURN NEW;
    END IF;

    v_payload := jsonb_build_object(
        'event_type', NEW.event_type,
        'activity_id', NEW.id,
        'booking_id', NEW.booking_id,
        'checkin_id', NEW.checkin_id,
        'location_id', NEW.location_id,
        'bookable_id', NEW.bookable_id,
        'bookable_type_id', NEW.bookable_type_id,
        'user_id', NEW.user_id,
        'organization_id', NEW.organization_id,
        'sa_owner_id', NEW.sa_owner_id,
        'started_at', NEW.started_at,
        'ended_at', NEW.ended_at,
        'bookable', NEW.bookable,
        'location', NEW.location,
        'owner', NEW.owner,
        'samna_user', NEW.samna_user,
        'bookable_type', NEW.bookable_type,
        'checkin', NEW.checkin
    );

    INSERT INTO event_queue (
        event_webhook_id,
        activity_id,
        event_type,
        payload,
        sa_owner_id
    )
    SELECT
        w.id,
        NEW.id,
        NEW.event_type,
        v_payload,
        NEW.sa_owner_id
    FROM event_webhook w
    WHERE w.sa_owner_id = NEW.sa_owner_id
      AND w.active = TRUE
      AND w.sa_deleted_at IS NULL
      AND (w.event_name IS NULL OR w.event_name = NEW.event_type);

    PERFORM pg_notify('event_queue', '');

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
