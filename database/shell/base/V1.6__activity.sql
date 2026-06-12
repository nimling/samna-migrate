CREATE OR REPLACE FUNCTION jsonify_bookable(bookable_id uuid)
RETURNS jsonb AS $$
DECLARE
    result jsonb;
    capability_json jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', b.id,
        'name', b.name,
        'description', b.description,
        'type_id', b.type_id,
        'sa_location_id', b.sa_location_id
    ) INTO result
    FROM bookable b
    WHERE b.id = bookable_id;

    SELECT c.value
    INTO capability_json
    FROM object_capability oc
    JOIN capability c ON oc.capability_id = c.id
    WHERE oc.object_id = bookable_id
    AND oc.object_type = 'public.bookable'
    LIMIT 1;

    result := result || jsonb_build_object(
        'capability', COALESCE(capability_json, '{}'::jsonb)
    );

    RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION jsonify_location(location_id uuid)
RETURNS jsonb AS $$
DECLARE
    result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', l.id,
        'name', l.name,
        'description', l.description,
        'type', l.type,
        'sa_level', l.sa_level
    ) INTO result
    FROM claimius.location l
    WHERE l.id = location_id;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION jsonify_bookable_type(type_id uuid)
RETURNS jsonb AS $$
DECLARE
    result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', bt.id,
        'name', bt.name,
        'description', bt.description,
        'keywords', bt.keywords
    ) INTO result
    FROM bookable_type bt
    WHERE bt.id = type_id;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION jsonify_organization(org_id uuid)
RETURNS jsonb AS $$
DECLARE
    result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', o.id,
        'name', o.name,
        'description', o.description,
        'type', o.type,
        'sa_level', o.sa_level
    ) INTO result
    FROM claimius.organization o
    WHERE o.id = org_id;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION jsonify_user(p_user_id uuid)
RETURNS jsonb AS $$
DECLARE
    result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', u.id,
        'user_id', u.user_id,
        'first_name', u.first_name,
        'last_name', u.last_name,
        'email', u.email,
        'type', u.type
    ) INTO result
    FROM claimius.samna_user u
    WHERE u.user_id = p_user_id;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION jsonify_checkin(checkin_id uuid)
RETURNS jsonb AS $$
DECLARE
    result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', c.id,
        'starts_at', c.starts_at,
        'ends_at', c.ends_at,
        'object_type', c.object_type,
        'object_id', c.object_id,
        'check_in', c.check_in,
        'check_out', c.check_out,
        'status', CASE
            WHEN c.check_in IS NOT NULL AND c.check_out IS NOT NULL THEN 'completed'
            WHEN c.check_in IS NOT NULL THEN 'checked_in'
            WHEN NOW() > c.ends_at THEN 'failed'
            ELSE 'pending'
        END
    ) INTO result
    FROM checkin c
    WHERE c.id = checkin_id;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_booking_activity()
RETURNS TRIGGER AS $$
DECLARE
    bookable_data jsonb;
    location_data jsonb;
    organization_data jsonb;
    bookable_type_data jsonb;
    user_data jsonb;
    checkin_data jsonb;
    location_id uuid;
    bookable_type_id uuid;
    occurrence_record RECORD;
    correlation_id uuid;
    seq_num integer := 0;
BEGIN
    correlation_id := gen_random_uuid();

    SELECT b.sa_location_id, b.type_id
    INTO location_id, bookable_type_id
    FROM bookable b
    WHERE b.id = NEW.bookable_id;

    bookable_data := jsonify_bookable(NEW.bookable_id);
    IF location_id IS NOT NULL THEN
        location_data := jsonify_location(location_id);
    END IF;

    organization_data := jsonify_organization(NEW.sa_owner_id);

    IF bookable_type_id IS NOT NULL THEN
        bookable_type_data := jsonify_bookable_type(bookable_type_id);
    END IF;

    SELECT jsonify_user(u.user_id) INTO user_data
    FROM claimius.user_claim uc
    JOIN claimius.samna_user u ON uc.user_id = u.user_id
    WHERE uc.id = NEW.sa_created_by;

    IF NEW.checkin_id IS NOT NULL THEN
        checkin_data := jsonify_checkin(NEW.checkin_id);
    END IF;

    FOR occurrence_record IN
        SELECT occ.next_start, occ.next_end
        FROM LATERAL calculate_next_occurrence(NEW.schedule, NOW() - INTERVAL '10 years') occ
        WHERE occ.next_start IS NOT NULL
        LIMIT 1000
    LOOP
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
            sa_owner_id
        ) VALUES (
            'booking_created',
            NEW.id,
            NEW.checkin_id,
            location_id,
            NEW.bookable_id,
            bookable_type_id,
            (user_data->>'user_id')::uuid,
            NEW.sa_owner_id,
            occurrence_record.next_start,
            occurrence_record.next_end,
            location_data,
            organization_data,
            user_data,
            bookable_data,
            bookable_type_data,
            checkin_data,
            NEW.sa_created_by,
            correlation_id,
            seq_num,
            NEW.sa_owner_id
        );

        seq_num := seq_num + 1;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_checkin_activity()
RETURNS TRIGGER AS $$
DECLARE
    booking_record RECORD;
    bookable_data jsonb;
    location_data jsonb;
    organization_data jsonb;
    bookable_type_data jsonb;
    user_data jsonb;
    checkin_data jsonb;
    location_id uuid;
    bookable_type_id uuid;
    event_type varchar;
    prev_activity_id uuid;
    seq_num integer;
    corr_id uuid;
    next_occurrence RECORD;
BEGIN
    checkin_data := jsonify_checkin(NEW.id);

    SELECT b.*, COUNT(a.id) as activity_count, MAX(a.sequence) as max_seq, a.correlation_id
    INTO booking_record
    FROM booking b
    LEFT JOIN activity a ON a.booking_id = b.id
    WHERE b.checkin_id = NEW.id
    GROUP BY b.id, a.correlation_id
    LIMIT 1;

    IF TG_OP = 'INSERT' THEN
        event_type := 'checkin_created';
    ELSIF NEW.check_in IS NOT NULL AND (OLD.check_in IS NULL OR NEW.check_in <> OLD.check_in) THEN
        event_type := 'checkin_started';
    ELSIF NEW.check_out IS NOT NULL AND (OLD.check_out IS NULL OR NEW.check_out <> OLD.check_out) THEN
        event_type := 'checkout_completed';
    ELSE
        event_type := 'checkin_updated';
    END IF;

    IF booking_record.activity_count > 0 THEN
        seq_num := booking_record.max_seq + 1;
        corr_id := booking_record.correlation_id;

        SELECT id INTO prev_activity_id
        FROM activity
        WHERE booking_id = booking_record.id
        ORDER BY sequence DESC
        LIMIT 1;
    ELSE
        seq_num := 0;
        corr_id := gen_random_uuid();
        prev_activity_id := NULL;
    END IF;

    IF booking_record.id IS NOT NULL THEN
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

        SELECT jsonify_user(u.user_id) INTO user_data
        FROM claimius.user_claim uc
        JOIN claimius.samna_user u ON uc.user_id = u.user_id
        WHERE uc.id = booking_record.sa_created_by;

        SELECT * INTO next_occurrence FROM calculate_next_occurrence(booking_record.schedule, NOW() - INTERVAL '1 year');

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
            NEW.id,
            location_id,
            booking_record.bookable_id,
            bookable_type_id,
            (user_data->>'user_id')::uuid,
            booking_record.sa_owner_id,
            COALESCE(next_occurrence.next_start, NEW.starts_at),
            COALESCE(next_occurrence.next_end, NEW.ends_at),
            location_data,
            organization_data,
            user_data,
            bookable_data,
            bookable_type_data,
            checkin_data,
            COALESCE(NEW.sa_created_by, booking_record.sa_created_by),
            corr_id,
            seq_num,
            prev_activity_id,
            booking_record.sa_owner_id
        );
    ELSE
        INSERT INTO activity (
            event_type,
            checkin_id,
            started_at,
            ended_at,
            checkin,
            sa_created_by,
            correlation_id,
            sequence,
            sa_owner_id
        ) VALUES (
            event_type,
            NEW.id,
            NEW.starts_at,
            NEW.ends_at,
            checkin_data,
            NEW.sa_created_by,
            gen_random_uuid(),
            0,
            NEW.sa_owner_id
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_booking_on_checkin_change()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE booking
    SET sa_updated_at = NOW()
    WHERE checkin_id = NEW.id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_booking_update_activity()
RETURNS TRIGGER AS $$
DECLARE
    bookable_data jsonb;
    location_data jsonb;
    organization_data jsonb;
    bookable_type_data jsonb;
    user_data jsonb;
    checkin_data jsonb;
    v_location_id uuid;
    v_bookable_type_id uuid;
    event_type varchar;
    correlation_id uuid;
    seq_num integer;
    prev_activity_id uuid;
BEGIN
    IF OLD.canceled_at IS NULL AND NEW.canceled_at IS NOT NULL THEN
        event_type := 'booking_canceled';
    ELSIF OLD.sa_deleted_at IS NULL AND NEW.sa_deleted_at IS NOT NULL THEN
        event_type := 'booking_deleted';
    ELSIF OLD.schedule IS DISTINCT FROM NEW.schedule
        OR OLD.name IS DISTINCT FROM NEW.name
        OR OLD.description IS DISTINCT FROM NEW.description THEN
        event_type := 'booking_updated';
    ELSE
        RETURN NEW;
    END IF;

    correlation_id := gen_random_uuid();

    SELECT b.sa_location_id, b.type_id
    INTO v_location_id, v_bookable_type_id
    FROM bookable b
    WHERE b.id = NEW.bookable_id;

    bookable_data := jsonify_bookable(NEW.bookable_id);
    IF v_location_id IS NOT NULL THEN
        location_data := jsonify_location(v_location_id);
    END IF;

    organization_data := jsonify_organization(NEW.sa_owner_id);

    IF v_bookable_type_id IS NOT NULL THEN
        bookable_type_data := jsonify_bookable_type(v_bookable_type_id);
    END IF;

    SELECT jsonify_user(u.user_id) INTO user_data
    FROM claimius.user_claim uc
    JOIN claimius.samna_user u ON uc.user_id = u.user_id
    WHERE uc.id = NEW.sa_created_by;

    IF NEW.checkin_id IS NOT NULL THEN
        checkin_data := jsonify_checkin(NEW.checkin_id);
    END IF;

    SELECT COUNT(*), MAX(a.sequence), a.correlation_id
    INTO seq_num, seq_num, correlation_id
    FROM activity a
    WHERE a.booking_id = NEW.id
    GROUP BY a.correlation_id
    LIMIT 1;

    IF seq_num IS NULL THEN
        seq_num := 0;
        correlation_id := gen_random_uuid();
    ELSE
        seq_num := seq_num + 1;
    END IF;

    SELECT id INTO prev_activity_id
    FROM activity
    WHERE booking_id = NEW.id
    ORDER BY sequence DESC
    LIMIT 1;

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
        NEW.id,
        NEW.checkin_id,
        v_location_id,
        NEW.bookable_id,
        v_bookable_type_id,
        (user_data->>'user_id')::uuid,
        NEW.sa_owner_id,
        (NEW.schedule->>'start_date')::timestamptz,
        COALESCE((NEW.schedule->>'end_date')::timestamptz, (NEW.schedule->>'start_date')::timestamptz + INTERVAL '1 hour'),
        location_data,
        organization_data,
        user_data,
        bookable_data,
        bookable_type_data,
        checkin_data,
        NEW.sa_created_by,
        correlation_id,
        seq_num,
        prev_activity_id,
        NEW.sa_owner_id
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tr_booking_insert_activity ON booking;
CREATE TRIGGER tr_booking_insert_activity
AFTER INSERT ON booking
FOR EACH ROW
EXECUTE FUNCTION create_booking_activity();

DROP TRIGGER IF EXISTS tr_booking_update_activity ON booking;
CREATE TRIGGER tr_booking_update_activity
AFTER UPDATE ON booking
FOR EACH ROW
EXECUTE FUNCTION create_booking_update_activity();

DROP TRIGGER IF EXISTS tr_checkin_activity ON checkin;
CREATE TRIGGER tr_checkin_activity
AFTER INSERT OR UPDATE ON checkin
FOR EACH ROW
EXECUTE FUNCTION create_checkin_activity();

DROP TRIGGER IF EXISTS tr_update_booking_on_checkin_change ON checkin;
CREATE TRIGGER tr_update_booking_on_checkin_change
AFTER UPDATE ON checkin
FOR EACH ROW
WHEN ((OLD.check_in IS NULL AND NEW.check_in IS NOT NULL) OR (OLD.check_out IS NULL AND NEW.check_out IS NOT NULL))
EXECUTE FUNCTION update_booking_on_checkin_change();

CREATE UNIQUE INDEX IF NOT EXISTS uq_activity_booking_ended
    ON activity (booking_id, started_at)
    WHERE event_type = 'booking_ended';

CREATE UNIQUE INDEX IF NOT EXISTS uq_activity_checkin_failed
    ON activity (checkin_id)
    WHERE event_type = 'checkin_failed';

CREATE OR REPLACE FUNCTION record_ended_bookings()
    RETURNS SETOF activity AS
$$
BEGIN
    IF NOT pg_try_advisory_xact_lock(742891) THEN
        RETURN;
    END IF;

    RETURN QUERY
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
    )
    SELECT
        'booking_ended',
        a.booking_id,
        a.checkin_id,
        a.location_id,
        a.bookable_id,
        a.bookable_type_id,
        a.user_id,
        a.organization_id,
        a.started_at,
        a.ended_at,
        a.location,
        a.owner,
        a.samna_user,
        a.bookable,
        a.bookable_type,
        a.checkin,
        a.sa_created_by,
        a.correlation_id,
        a.sequence,
        a.id,
        a.sa_owner_id
    FROM activity a
    WHERE a.event_type = 'booking_created'
      AND a.ended_at < NOW()
      AND NOT EXISTS (
        SELECT 1
          FROM activity b
         WHERE b.event_type = 'booking_ended'
           AND b.booking_id = a.booking_id
           AND b.started_at = a.started_at
      )
    ON CONFLICT (booking_id, started_at) WHERE event_type = 'booking_ended' DO NOTHING
    RETURNING *;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_failed_checkins()
    RETURNS SETOF activity AS
$$
BEGIN
    IF NOT pg_try_advisory_xact_lock(742892) THEN
        RETURN;
    END IF;

    RETURN QUERY
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
    )
    SELECT
        'checkin_failed',
        b.id,
        c.id,
        bk.sa_location_id,
        bk.id,
        bk.type_id,
        u.user_id,
        b.sa_owner_id,
        c.starts_at,
        c.ends_at,
        CASE WHEN bk.sa_location_id IS NOT NULL THEN jsonify_location(bk.sa_location_id) END,
        CASE WHEN b.sa_owner_id IS NOT NULL THEN jsonify_organization(b.sa_owner_id) END,
        CASE WHEN u.user_id IS NOT NULL THEN jsonify_user(u.user_id) END,
        CASE WHEN bk.id IS NOT NULL THEN jsonify_bookable(bk.id) END,
        CASE WHEN bk.type_id IS NOT NULL THEN jsonify_bookable_type(bk.type_id) END,
        jsonify_checkin(c.id),
        b.sa_created_by,
        COALESCE(
            (SELECT a.correlation_id FROM activity a WHERE a.booking_id = b.id LIMIT 1),
            gen_random_uuid()
        ),
        COALESCE(
            (SELECT MAX(a.sequence) + 1 FROM activity a WHERE a.booking_id = b.id),
            0
        ),
        (SELECT a.id FROM activity a WHERE a.booking_id = b.id ORDER BY a.sequence DESC LIMIT 1),
        c.sa_owner_id
    FROM checkin c
    LEFT JOIN booking b ON b.checkin_id = c.id AND b.sa_deleted_at IS NULL
    LEFT JOIN bookable bk ON bk.id = b.bookable_id AND bk.sa_deleted_at IS NULL
    LEFT JOIN claimius.user_claim uc ON uc.id = b.sa_created_by
    LEFT JOIN claimius.samna_user u ON uc.user_id = u.user_id
    WHERE c.check_in IS NULL
      AND c.ends_at < NOW()
      AND c.sa_deleted_at IS NULL
      AND NOT EXISTS (
        SELECT 1
          FROM activity a
         WHERE a.event_type = 'checkin_failed'
           AND a.checkin_id = c.id
      )
    ON CONFLICT (checkin_id) WHERE event_type = 'checkin_failed' DO NOTHING
    RETURNING *;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION next_record_deadline()
    RETURNS timestamptz AS
$$
DECLARE
    v_next timestamptz;
BEGIN
    SELECT LEAST(
        (
            SELECT MIN(a.ended_at)
              FROM activity a
             WHERE a.event_type = 'booking_created'
               AND a.ended_at > NOW()
               AND NOT EXISTS (
                 SELECT 1
                   FROM activity b
                  WHERE b.event_type = 'booking_ended'
                    AND b.booking_id = a.booking_id
                    AND b.started_at = a.started_at
               )
        ),
        (
            SELECT MIN(c.ends_at)
              FROM checkin c
             WHERE c.check_in IS NULL
               AND c.ends_at > NOW()
               AND c.sa_deleted_at IS NULL
               AND NOT EXISTS (
                 SELECT 1
                   FROM activity a
                  WHERE a.event_type = 'checkin_failed'
                    AND a.checkin_id = c.id
               )
        )
    ) INTO v_next;

    RETURN v_next;
END;
$$ LANGUAGE plpgsql;

CREATE UNLOGGED TABLE IF NOT EXISTS action_queue
(
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq               bigserial   NOT NULL,
    action_id         uuid        NOT NULL REFERENCES action (id),
    action_object_id  uuid        NOT NULL REFERENCES action_object (id),
    event_type        varchar     NOT NULL,
    fire_at           timestamptz NOT NULL,
    payload           jsonb       NOT NULL DEFAULT '{}'::jsonb,
    affects_objects   jsonb       NOT NULL DEFAULT '[]'::jsonb,
    claimed_by        uuid,
    claimed_at        timestamptz,
    processed_at      timestamptz,
    attempts          integer     NOT NULL DEFAULT 0,
    failure_reason    text,
    sa_owner_id       uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_deleted_at     timestamptz,
    sa_created_at     timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at     timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_action_queue_fire_at ON action_queue (fire_at) WHERE processed_at IS NULL AND sa_deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_action_queue_action_object_id ON action_queue (action_object_id);
CREATE INDEX IF NOT EXISTS idx_action_queue_action_id ON action_queue (action_id);
CREATE INDEX IF NOT EXISTS idx_action_queue_sa_owner_id ON action_queue (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_action_queue_event_type ON action_queue (event_type);
CREATE INDEX IF NOT EXISTS idx_action_queue_affects_objects ON action_queue USING GIN (affects_objects);
CREATE INDEX IF NOT EXISTS idx_action_queue_seq ON action_queue (seq);

CREATE UNLOGGED TABLE IF NOT EXISTS event_queue
(
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq               bigserial   NOT NULL,
    event_webhook_id  uuid        NOT NULL REFERENCES event_webhook (id),
    activity_id       uuid        NOT NULL REFERENCES activity (id),
    event_type        varchar     NOT NULL,
    payload           jsonb       NOT NULL DEFAULT '{}'::jsonb,
    fire_at           timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    claimed_by        uuid,
    claimed_at        timestamptz,
    processed_at      timestamptz,
    attempts          integer     NOT NULL DEFAULT 0,
    failure_reason    text,
    sa_owner_id       uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_deleted_at     timestamptz,
    sa_created_at     timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at     timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_event_queue_fire_at ON event_queue (fire_at) WHERE processed_at IS NULL AND sa_deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_event_queue_event_webhook_id ON event_queue (event_webhook_id);
CREATE INDEX IF NOT EXISTS idx_event_queue_sa_owner_id ON event_queue (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_event_queue_seq ON event_queue (seq);

CREATE OR REPLACE FUNCTION enqueue_activity_consumers()
RETURNS TRIGGER AS $$
DECLARE
    v_payload jsonb;
BEGIN
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

DROP TRIGGER IF EXISTS tr_activity_enqueue_consumers ON activity;
CREATE TRIGGER tr_activity_enqueue_consumers
    AFTER INSERT ON activity
    FOR EACH ROW
    EXECUTE FUNCTION enqueue_activity_consumers();
