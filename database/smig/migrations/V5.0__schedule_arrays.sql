ALTER TABLE booking
    ADD COLUMN IF NOT EXISTS cancellation jsonb;

ALTER FUNCTION is_schedule_in_time_range(jsonb, timestamptz, timestamptz)
    RENAME TO _is_schedule_entry_in_time_range;

ALTER FUNCTION calculate_schedule_hours(jsonb, timestamptz, timestamptz)
    RENAME TO _calculate_schedule_entry_hours;

ALTER FUNCTION calculate_next_occurrence(jsonb, timestamptz)
    RENAME TO _calculate_next_occurrence_entry;

CREATE OR REPLACE FUNCTION is_schedule_in_time_range(
    p_set jsonb,
    p_start timestamptz,
    p_end timestamptz
) RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    entry jsonb;
BEGIN
    IF p_set IS NULL OR jsonb_array_length(p_set) = 0 THEN
        RETURN FALSE;
    END IF;
    FOR entry IN SELECT value FROM jsonb_array_elements(p_set) LOOP
        IF COALESCE((entry->>'available')::boolean, TRUE)
           AND _is_schedule_entry_in_time_range(entry, p_start, p_end) THEN
            RETURN TRUE;
        END IF;
    END LOOP;
    RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION calculate_schedule_hours(
    p_set jsonb,
    p_start timestamptz,
    p_end timestamptz
) RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    entry jsonb;
    h_open numeric := 0;
    h_blocked numeric := 0;
    e_hours numeric;
BEGIN
    IF p_set IS NULL OR jsonb_array_length(p_set) = 0 THEN
        RETURN 0;
    END IF;
    FOR entry IN SELECT value FROM jsonb_array_elements(p_set) LOOP
        e_hours := COALESCE(_calculate_schedule_entry_hours(entry, p_start, p_end), 0);
        IF COALESCE((entry->>'available')::boolean, TRUE) THEN
            h_open := h_open + e_hours;
        ELSE
            h_blocked := h_blocked + e_hours;
        END IF;
    END LOOP;
    RETURN GREATEST(h_open - h_blocked, 0);
END;
$$;

CREATE OR REPLACE FUNCTION calculate_next_occurrence(
    p_set jsonb,
    p_from timestamptz DEFAULT NOW(),
    OUT next_start timestamptz,
    OUT next_end timestamptz
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    entry jsonb;
    rec record;
BEGIN
    next_start := NULL;
    next_end := NULL;
    IF p_set IS NULL OR jsonb_array_length(p_set) = 0 THEN
        RETURN;
    END IF;
    FOR entry IN SELECT value FROM jsonb_array_elements(p_set) LOOP
        IF NOT COALESCE((entry->>'available')::boolean, TRUE) THEN
            CONTINUE;
        END IF;
        SELECT * INTO rec FROM _calculate_next_occurrence_entry(entry, p_from);
        IF rec.next_start IS NOT NULL AND (next_start IS NULL OR rec.next_start < next_start) THEN
            next_start := rec.next_start;
            next_end := rec.next_end;
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_booking_schedule(p_booking_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_schedule jsonb;
    v_cancellation jsonb;
BEGIN
    SELECT schedule, cancellation
    INTO v_schedule, v_cancellation
    FROM booking
    WHERE id = p_booking_id AND sa_deleted_at IS NULL;

    IF v_schedule IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_cancellation IS NULL OR jsonb_array_length(v_cancellation) = 0 THEN
        RETURN v_schedule;
    END IF;
    RETURN v_schedule || v_cancellation;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_timeslot_schedule(p_timeslot_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_schedule jsonb;
BEGIN
    SELECT schedule INTO v_schedule
    FROM timeslot
    WHERE id = p_timeslot_id AND sa_deleted_at IS NULL;
    RETURN v_schedule;
END;
$$;

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
        FROM LATERAL calculate_next_occurrence(public.get_booking_schedule(NEW.id), NOW() - INTERVAL '10 years') occ
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

        SELECT * INTO next_occurrence FROM calculate_next_occurrence(public.get_booking_schedule(booking_record.id), NOW() - INTERVAL '1 year');

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
    v_started_at timestamptz;
    v_ended_at timestamptz;
BEGIN
    IF OLD.canceled_at IS NULL AND NEW.canceled_at IS NOT NULL THEN
        event_type := 'booking_canceled';
    ELSIF OLD.sa_deleted_at IS NULL AND NEW.sa_deleted_at IS NOT NULL THEN
        event_type := 'booking_deleted';
    ELSIF OLD.schedule IS DISTINCT FROM NEW.schedule
        OR OLD.cancellation IS DISTINCT FROM NEW.cancellation
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

    SELECT MIN((e->>'start_date')::timestamptz)
    INTO v_started_at
    FROM jsonb_array_elements(NEW.schedule) e;

    SELECT MAX(COALESCE((e->>'end_date')::timestamptz, (e->>'start_date')::timestamptz + INTERVAL '1 hour'))
    INTO v_ended_at
    FROM jsonb_array_elements(NEW.schedule) e;

    IF v_started_at IS NULL THEN
        v_started_at := NOW();
    END IF;
    IF v_ended_at IS NULL THEN
        v_ended_at := v_started_at + INTERVAL '1 hour';
    END IF;

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
        v_started_at,
        v_ended_at,
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

UPDATE booking
SET schedule = jsonb_build_array(schedule)
WHERE jsonb_typeof(schedule) <> 'array';

UPDATE booking
SET cancellation = jsonb_build_array(cancellation)
WHERE cancellation IS NOT NULL
  AND jsonb_typeof(cancellation) <> 'array';

UPDATE timeslot
SET schedule = jsonb_build_array(schedule)
WHERE jsonb_typeof(schedule) <> 'array';

DROP INDEX IF EXISTS idx_booking_schedule;
CREATE INDEX IF NOT EXISTS idx_booking_schedule ON booking USING GIN (schedule jsonb_path_ops);
CREATE INDEX IF NOT EXISTS idx_booking_cancellation ON booking USING GIN (cancellation jsonb_path_ops);

ALTER TABLE booking
    DROP CONSTRAINT IF EXISTS booking_schedule_is_array,
    DROP CONSTRAINT IF EXISTS booking_cancellation_is_array;
ALTER TABLE booking
    ADD CONSTRAINT booking_schedule_is_array CHECK (jsonb_typeof(schedule) = 'array'),
    ADD CONSTRAINT booking_cancellation_is_array CHECK (cancellation IS NULL OR jsonb_typeof(cancellation) = 'array');

ALTER TABLE timeslot
    DROP CONSTRAINT IF EXISTS timeslot_schedule_is_array;
ALTER TABLE timeslot
    ADD CONSTRAINT timeslot_schedule_is_array CHECK (jsonb_typeof(schedule) = 'array');

CREATE OR REPLACE FUNCTION get_bookable_available_hours(
    p_bookable_id UUID,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
    RETURNS TABLE
            (
                bookable_id      UUID,
                bookable_name    TEXT,
                total_hours      NUMERIC,
                used_hours       NUMERIC,
                available_hours  NUMERIC,
                utilization_rate NUMERIC
            )
AS
$$
DECLARE
    total_period_hours NUMERIC;
    v_available_hours  NUMERIC;
    v_used_hours       NUMERIC;
    timeslot_records   RECORD;
    has_timeslots      BOOLEAN := FALSE;
    v_bookable_name    TEXT;
BEGIN
    SELECT name
    INTO v_bookable_name
    FROM bookable
    WHERE id = p_bookable_id
      AND sa_deleted_at IS NULL;

    total_period_hours := EXTRACT(EPOCH FROM (p_end_date - p_start_date)) / 3600;

    SELECT COALESCE(SUM(calculate_schedule_hours(public.get_booking_schedule(b.id), p_start_date, p_end_date)), 0)
    INTO v_used_hours
    FROM booking b
    WHERE b.bookable_id = p_bookable_id
      AND b.sa_deleted_at IS NULL
      AND is_schedule_in_time_range(public.get_booking_schedule(b.id), p_start_date, p_end_date);

    FOR timeslot_records IN
        SELECT t.id, t.schedule
        FROM object_timeslot ot
                 JOIN timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
        WHERE ot.object_id = p_bookable_id
          AND ot.object_type = 'public.bookable'
          AND ot.sa_deleted_at IS NULL
        LOOP
            has_timeslots := TRUE;
            IF is_schedule_in_time_range(timeslot_records.schedule, p_start_date, p_end_date) THEN
                NULL;
            END IF;
        END LOOP;

    IF NOT has_timeslots THEN
        FOR timeslot_records IN
            SELECT t.id, t.schedule
            FROM bookable b
                     JOIN claimius.location l ON b.sa_location_id = l.id
                     JOIN object_timeslot ot
                          ON ot.object_id = l.id AND ot.object_type = 'claimius.location' AND ot.sa_deleted_at IS NULL
                     JOIN timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
            WHERE b.id = p_bookable_id
              AND b.sa_deleted_at IS NULL
            LOOP
                has_timeslots := TRUE;
                IF is_schedule_in_time_range(timeslot_records.schedule, p_start_date, p_end_date) THEN
                    NULL;
                END IF;
            END LOOP;
    END IF;

    IF NOT has_timeslots THEN
        FOR timeslot_records IN
            SELECT t.id, t.schedule
            FROM bookable b
                     JOIN object_timeslot ot
                          ON ot.object_id = b.sa_owner_id AND ot.object_type = 'claimius.organization' AND ot.sa_deleted_at IS NULL
                     JOIN timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
            WHERE b.id = p_bookable_id
              AND b.sa_deleted_at IS NULL
            LOOP
                has_timeslots := TRUE;
                IF is_schedule_in_time_range(timeslot_records.schedule, p_start_date, p_end_date) THEN
                    NULL;
                END IF;
            END LOOP;
    END IF;

    IF has_timeslots THEN
        v_available_hours := total_period_hours * 0.4;
    ELSE
        v_available_hours := total_period_hours;
    END IF;

    RETURN QUERY
        SELECT p_bookable_id                               AS bookable_id,
               v_bookable_name                             AS bookable_name,
               (v_available_hours + v_used_hours)::NUMERIC AS total_hours,
               v_used_hours::NUMERIC                       AS used_hours,
               v_available_hours::NUMERIC                  AS available_hours,
               CASE
                   WHEN (v_available_hours + v_used_hours) > 0
                       THEN (v_used_hours / (v_available_hours + v_used_hours) * 100)::NUMERIC
                   ELSE 0::NUMERIC
                   END                                     AS utilization_rate;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION schedule_starts_at(p_set jsonb)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT MIN((e->>'start_date')::timestamptz)
    FROM jsonb_array_elements(COALESCE(p_set, '[]'::jsonb)) e
    WHERE COALESCE((e->>'available')::boolean, TRUE)
$$;

CREATE OR REPLACE FUNCTION schedule_ends_at(p_set jsonb)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN bool_or(e->>'end_date' IS NULL) THEN NULL
        ELSE MAX((e->>'end_date')::timestamptz)
    END
    FROM jsonb_array_elements(COALESCE(p_set, '[]'::jsonb)) e
    WHERE COALESCE((e->>'available')::boolean, TRUE)
$$;

CREATE OR REPLACE FUNCTION schedule_overlaps_range(
    p_set jsonb,
    p_start timestamptz,
    p_end timestamptz
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(COALESCE(p_set, '[]'::jsonb)) e
        WHERE COALESCE((e->>'available')::boolean, TRUE)
          AND (e->>'start_date')::timestamptz <= p_end
          AND (e->>'end_date' IS NULL OR (e->>'end_date')::timestamptz >= p_start)
    )
$$;

CREATE OR REPLACE FUNCTION booking_overlaps_range(
    p_booking_id uuid,
    p_start timestamptz,
    p_end timestamptz
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT schedule_overlaps_range(public.get_booking_schedule(p_booking_id), p_start, p_end)
$$;
