CREATE UNIQUE INDEX IF NOT EXISTS uq_activity_checkin_started
    ON activity (booking_id, started_at)
    WHERE event_type = 'checkin_started';

CREATE UNIQUE INDEX IF NOT EXISTS uq_activity_checkin_failed
    ON activity (booking_id, started_at)
    WHERE event_type = 'checkin_failed';

CREATE UNIQUE INDEX IF NOT EXISTS uq_activity_checkout_started
    ON activity (booking_id, ended_at)
    WHERE event_type = 'checkout_started';

CREATE UNIQUE INDEX IF NOT EXISTS uq_activity_checkout_failed
    ON activity (booking_id, ended_at)
    WHERE event_type = 'checkout_failed';

CREATE OR REPLACE FUNCTION record_opened_checkin_windows()
    RETURNS SETOF activity AS
$$
BEGIN
    IF NOT pg_try_advisory_xact_lock(742893) THEN
        RETURN;
    END IF;

    RETURN QUERY
    INSERT INTO activity (
        event_type, booking_id, checkin_id, location_id, bookable_id, bookable_type_id,
        user_id, organization_id, started_at, ended_at,
        location, owner, samna_user, bookable, bookable_type, checkin,
        sa_created_by, correlation_id, sequence, previous_activity_id, sa_owner_id
    )
    SELECT
        'checkin_started',
        bc.booking_id,
        bc.checkin_id,
        bc.location_id,
        bc.bookable_id,
        bc.bookable_type_id,
        bc.user_id,
        bc.organization_id,
        bc.started_at,
        bc.ended_at,
        bc.location,
        bc.owner,
        bc.samna_user,
        bc.bookable,
        bc.bookable_type,
        bc.checkin,
        bc.sa_created_by,
        bc.correlation_id,
        COALESCE((SELECT MAX(a.sequence) + 1 FROM activity a WHERE a.booking_id = bc.booking_id), 0),
        bc.id,
        bc.sa_owner_id
    FROM activity bc
    WHERE bc.event_type = 'booking_created'
      AND bc.sa_deleted_at IS NULL
      AND bc.checkin_id IS NOT NULL
      AND bc.checkin IS NOT NULL
      AND (bc.checkin->>'checkin_required')::boolean = TRUE
      AND bc.checkin->'checkin_window' IS NOT NULL
      AND bc.started_at - ((bc.checkin->'checkin_window'->>'from')::int * INTERVAL '1 minute') <= NOW()
      AND NOT EXISTS (
          SELECT 1 FROM activity a
          WHERE a.event_type = 'checkin_started'
            AND a.booking_id = bc.booking_id
            AND a.started_at = bc.started_at
      )
    ON CONFLICT (booking_id, started_at) WHERE event_type = 'checkin_started' DO NOTHING
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
        event_type, booking_id, checkin_id, location_id, bookable_id, bookable_type_id,
        user_id, organization_id, started_at, ended_at,
        location, owner, samna_user, bookable, bookable_type, checkin,
        sa_created_by, correlation_id, sequence, previous_activity_id, sa_owner_id
    )
    SELECT
        'checkin_failed',
        bc.booking_id,
        bc.checkin_id,
        bc.location_id,
        bc.bookable_id,
        bc.bookable_type_id,
        bc.user_id,
        bc.organization_id,
        bc.started_at,
        bc.ended_at,
        bc.location,
        bc.owner,
        bc.samna_user,
        bc.bookable,
        bc.bookable_type,
        bc.checkin,
        bc.sa_created_by,
        bc.correlation_id,
        COALESCE((SELECT MAX(a.sequence) + 1 FROM activity a WHERE a.booking_id = bc.booking_id), 0),
        bc.id,
        bc.sa_owner_id
    FROM activity bc
    WHERE bc.event_type = 'booking_created'
      AND bc.sa_deleted_at IS NULL
      AND bc.checkin_id IS NOT NULL
      AND bc.checkin IS NOT NULL
      AND (bc.checkin->>'checkin_required')::boolean = TRUE
      AND bc.checkin->'checkin_window' IS NOT NULL
      AND bc.started_at + ((bc.checkin->'checkin_window'->>'to')::int * INTERVAL '1 minute') <= NOW()
      AND NOT EXISTS (
          SELECT 1 FROM activity a
          WHERE a.event_type = 'checkin_completed'
            AND a.booking_id = bc.booking_id
            AND a.started_at = bc.started_at
      )
      AND NOT EXISTS (
          SELECT 1 FROM activity a
          WHERE a.event_type = 'checkin_failed'
            AND a.booking_id = bc.booking_id
            AND a.started_at = bc.started_at
      )
    ON CONFLICT (booking_id, started_at) WHERE event_type = 'checkin_failed' DO NOTHING
    RETURNING *;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_opened_checkout_windows()
    RETURNS SETOF activity AS
$$
BEGIN
    IF NOT pg_try_advisory_xact_lock(742894) THEN
        RETURN;
    END IF;

    RETURN QUERY
    INSERT INTO activity (
        event_type, booking_id, checkin_id, location_id, bookable_id, bookable_type_id,
        user_id, organization_id, started_at, ended_at,
        location, owner, samna_user, bookable, bookable_type, checkin,
        sa_created_by, correlation_id, sequence, previous_activity_id, sa_owner_id
    )
    SELECT
        'checkout_started',
        bc.booking_id,
        bc.checkin_id,
        bc.location_id,
        bc.bookable_id,
        bc.bookable_type_id,
        bc.user_id,
        bc.organization_id,
        bc.started_at,
        bc.ended_at,
        bc.location,
        bc.owner,
        bc.samna_user,
        bc.bookable,
        bc.bookable_type,
        bc.checkin,
        bc.sa_created_by,
        bc.correlation_id,
        COALESCE((SELECT MAX(a.sequence) + 1 FROM activity a WHERE a.booking_id = bc.booking_id), 0),
        bc.id,
        bc.sa_owner_id
    FROM activity bc
    WHERE bc.event_type = 'booking_created'
      AND bc.sa_deleted_at IS NULL
      AND bc.checkin_id IS NOT NULL
      AND bc.checkin IS NOT NULL
      AND (bc.checkin->>'checkout_required')::boolean = TRUE
      AND bc.checkin->'checkout_window' IS NOT NULL
      AND bc.ended_at - ((bc.checkin->'checkout_window'->>'from')::int * INTERVAL '1 minute') <= NOW()
      AND NOT EXISTS (
          SELECT 1 FROM activity a
          WHERE a.event_type = 'checkout_started'
            AND a.booking_id = bc.booking_id
            AND a.ended_at = bc.ended_at
      )
    ON CONFLICT (booking_id, ended_at) WHERE event_type = 'checkout_started' DO NOTHING
    RETURNING *;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_failed_checkouts()
    RETURNS SETOF activity AS
$$
BEGIN
    IF NOT pg_try_advisory_xact_lock(742895) THEN
        RETURN;
    END IF;

    RETURN QUERY
    INSERT INTO activity (
        event_type, booking_id, checkin_id, location_id, bookable_id, bookable_type_id,
        user_id, organization_id, started_at, ended_at,
        location, owner, samna_user, bookable, bookable_type, checkin,
        sa_created_by, correlation_id, sequence, previous_activity_id, sa_owner_id
    )
    SELECT
        'checkout_failed',
        bc.booking_id,
        bc.checkin_id,
        bc.location_id,
        bc.bookable_id,
        bc.bookable_type_id,
        bc.user_id,
        bc.organization_id,
        bc.started_at,
        bc.ended_at,
        bc.location,
        bc.owner,
        bc.samna_user,
        bc.bookable,
        bc.bookable_type,
        bc.checkin,
        bc.sa_created_by,
        bc.correlation_id,
        COALESCE((SELECT MAX(a.sequence) + 1 FROM activity a WHERE a.booking_id = bc.booking_id), 0),
        bc.id,
        bc.sa_owner_id
    FROM activity bc
    WHERE bc.event_type = 'booking_created'
      AND bc.sa_deleted_at IS NULL
      AND bc.checkin_id IS NOT NULL
      AND bc.checkin IS NOT NULL
      AND (bc.checkin->>'checkout_required')::boolean = TRUE
      AND bc.checkin->'checkout_window' IS NOT NULL
      AND bc.ended_at + ((bc.checkin->'checkout_window'->>'to')::int * INTERVAL '1 minute') <= NOW()
      AND NOT EXISTS (
          SELECT 1 FROM activity a
          WHERE a.event_type = 'checkout_completed'
            AND a.booking_id = bc.booking_id
            AND a.ended_at = bc.ended_at
      )
      AND NOT EXISTS (
          SELECT 1 FROM activity a
          WHERE a.event_type = 'checkout_failed'
            AND a.booking_id = bc.booking_id
            AND a.ended_at = bc.ended_at
      )
    ON CONFLICT (booking_id, ended_at) WHERE event_type = 'checkout_failed' DO NOTHING
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
               AND a.sa_deleted_at IS NULL
               AND a.ended_at > NOW()
               AND NOT EXISTS (
                   SELECT 1 FROM activity b
                   WHERE b.event_type = 'booking_ended'
                     AND b.booking_id = a.booking_id
                     AND b.started_at = a.started_at
               )
        ),
        (
            SELECT MIN(a.started_at - ((a.checkin->'checkin_window'->>'from')::int * INTERVAL '1 minute'))
              FROM activity a
             WHERE a.event_type = 'booking_created'
               AND a.sa_deleted_at IS NULL
               AND a.checkin IS NOT NULL
               AND (a.checkin->>'checkin_required')::boolean = TRUE
               AND a.checkin->'checkin_window' IS NOT NULL
               AND a.started_at - ((a.checkin->'checkin_window'->>'from')::int * INTERVAL '1 minute') > NOW()
               AND NOT EXISTS (
                   SELECT 1 FROM activity b
                   WHERE b.event_type = 'checkin_started'
                     AND b.booking_id = a.booking_id
                     AND b.started_at = a.started_at
               )
        ),
        (
            SELECT MIN(a.started_at + ((a.checkin->'checkin_window'->>'to')::int * INTERVAL '1 minute'))
              FROM activity a
             WHERE a.event_type = 'booking_created'
               AND a.sa_deleted_at IS NULL
               AND a.checkin IS NOT NULL
               AND (a.checkin->>'checkin_required')::boolean = TRUE
               AND a.checkin->'checkin_window' IS NOT NULL
               AND a.started_at + ((a.checkin->'checkin_window'->>'to')::int * INTERVAL '1 minute') > NOW()
               AND NOT EXISTS (
                   SELECT 1 FROM activity b
                   WHERE b.event_type IN ('checkin_completed','checkin_failed')
                     AND b.booking_id = a.booking_id
                     AND b.started_at = a.started_at
               )
        ),
        (
            SELECT MIN(a.ended_at - ((a.checkin->'checkout_window'->>'from')::int * INTERVAL '1 minute'))
              FROM activity a
             WHERE a.event_type = 'booking_created'
               AND a.sa_deleted_at IS NULL
               AND a.checkin IS NOT NULL
               AND (a.checkin->>'checkout_required')::boolean = TRUE
               AND a.checkin->'checkout_window' IS NOT NULL
               AND a.ended_at - ((a.checkin->'checkout_window'->>'from')::int * INTERVAL '1 minute') > NOW()
               AND NOT EXISTS (
                   SELECT 1 FROM activity b
                   WHERE b.event_type = 'checkout_started'
                     AND b.booking_id = a.booking_id
                     AND b.ended_at = a.ended_at
               )
        ),
        (
            SELECT MIN(a.ended_at + ((a.checkin->'checkout_window'->>'to')::int * INTERVAL '1 minute'))
              FROM activity a
             WHERE a.event_type = 'booking_created'
               AND a.sa_deleted_at IS NULL
               AND a.checkin IS NOT NULL
               AND (a.checkin->>'checkout_required')::boolean = TRUE
               AND a.checkin->'checkout_window' IS NOT NULL
               AND a.ended_at + ((a.checkin->'checkout_window'->>'to')::int * INTERVAL '1 minute') > NOW()
               AND NOT EXISTS (
                   SELECT 1 FROM activity b
                   WHERE b.event_type IN ('checkout_completed','checkout_failed')
                     AND b.booking_id = a.booking_id
                     AND b.ended_at = a.ended_at
               )
        )
    ) INTO v_next;

    RETURN v_next;
END;
$$ LANGUAGE plpgsql;
