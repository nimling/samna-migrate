DROP TRIGGER IF EXISTS tr_checkin_activity ON checkin;
DROP TRIGGER IF EXISTS tr_update_booking_on_checkin_change ON checkin;
DROP FUNCTION IF EXISTS create_checkin_activity();
DROP FUNCTION IF EXISTS update_booking_on_checkin_change();

CREATE OR REPLACE FUNCTION jsonify_checkin(checkin_id uuid)
RETURNS jsonb AS $$
DECLARE
    result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', c.id,
        'object_type', c.object_type,
        'object_id', c.object_id,
        'checkin_window', c.checkin_window,
        'checkout_window', c.checkout_window,
        'checkin_required', c.checkin_required,
        'checkout_required', c.checkout_required,
        'require_all', c.require_all,
        'inherits', c.inherits,
        'schedule', c.schedule
    ) INTO result
    FROM checkin c
    WHERE c.id = checkin_id;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION jsonify_object_checkin(object_checkin_id uuid)
RETURNS jsonb AS $$
DECLARE
    result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', oc.id,
        'checkin_id', oc.checkin_id,
        'booking_id', oc.booking_id,
        'user_id', oc.user_id,
        'checkin_at', oc.checkin_at,
        'checkout_at', oc.checkout_at,
        'created_at', oc.sa_created_at,
        'updated_at', oc.sa_updated_at
    ) INTO result
    FROM object_checkin oc
    WHERE oc.id = object_checkin_id;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_object_checkin_activity()
RETURNS TRIGGER AS $$
DECLARE
    booking_record       RECORD;
    location_id          uuid;
    bookable_type_id     uuid;
    event_type           varchar;
    bookable_data        jsonb;
    location_data        jsonb;
    organization_data    jsonb;
    bookable_type_data   jsonb;
    user_data            jsonb;
    checkin_data         jsonb;
    object_checkin_data  jsonb;
    seq_num              integer;
    corr_id              uuid;
    prev_activity_id     uuid;
    started              timestamptz;
    ended                timestamptz;
    next_occurrence      RECORD;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.checkin_at IS NULL THEN
            RETURN NEW;
        END IF;
        event_type := 'checkin_completed';
    ELSE
        IF NEW.checkout_at IS NULL OR OLD.checkout_at IS NOT NULL THEN
            RETURN NEW;
        END IF;
        event_type := 'checkout_completed';
    END IF;

    SELECT *
    INTO booking_record
    FROM booking b
    WHERE b.id = NEW.booking_id
      AND b.sa_deleted_at IS NULL;

    IF booking_record.id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT b.sa_location_id, b.type_id
    INTO location_id, bookable_type_id
    FROM bookable b
    WHERE b.id = booking_record.bookable_id;

    bookable_data := jsonify_bookable(booking_record.bookable_id);
    IF location_id IS NOT NULL THEN
        location_data := jsonify_location(location_id);
    END IF;
    organization_data := jsonify_organization(booking_record.sa_owner_id);
    IF bookable_type_id IS NOT NULL THEN
        bookable_type_data := jsonify_bookable_type(bookable_type_id);
    END IF;
    user_data := jsonify_user(NEW.user_id);
    checkin_data := jsonify_checkin(NEW.checkin_id);
    object_checkin_data := jsonify_object_checkin(NEW.id);

    SELECT MAX(a.sequence), a.correlation_id
    INTO seq_num, corr_id
    FROM activity a
    WHERE a.booking_id = booking_record.id
    GROUP BY a.correlation_id
    LIMIT 1;

    IF seq_num IS NULL THEN
        seq_num := 0;
        corr_id := gen_random_uuid();
    ELSE
        seq_num := seq_num + 1;
    END IF;

    SELECT a.id INTO prev_activity_id
    FROM activity a
    WHERE a.booking_id = booking_record.id
    ORDER BY a.sequence DESC
    LIMIT 1;

    SELECT * INTO next_occurrence FROM calculate_next_occurrence(booking_record.schedule, NOW() - INTERVAL '1 year');
    started := COALESCE(next_occurrence.next_start, NOW());
    ended := COALESCE(next_occurrence.next_end, NOW());

    INSERT INTO activity (
        event_type,
        booking_id,
        checkin_id,
        location_id,
        bookable_id,
        bookable_type_id,
        user_id,
        organization_id,
        started_at,
        ended_at,
        location,
        owner,
        samna_user,
        bookable,
        bookable_type,
        checkin,
        sa_created_by,
        correlation_id,
        sequence,
        previous_activity_id,
        sa_owner_id
    ) VALUES (
        event_type,
        booking_record.id,
        NEW.checkin_id,
        location_id,
        booking_record.bookable_id,
        bookable_type_id,
        NEW.user_id,
        booking_record.sa_owner_id,
        started,
        ended,
        location_data,
        organization_data,
        user_data,
        bookable_data,
        bookable_type_data,
        checkin_data || jsonb_build_object('object_checkin', object_checkin_data),
        NEW.sa_created_by,
        corr_id,
        seq_num,
        prev_activity_id,
        NEW.sa_owner_id
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tr_object_checkin_activity ON object_checkin;
CREATE TRIGGER tr_object_checkin_activity
AFTER INSERT OR UPDATE ON object_checkin
FOR EACH ROW
EXECUTE FUNCTION create_object_checkin_activity();
