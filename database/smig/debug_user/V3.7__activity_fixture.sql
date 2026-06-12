SELECT set_config('sauth.debug_user_id', :'sauth_debug_user_id', true);
SELECT set_config('sauth.app_slug', :'sauth_app_slug', true);
SELECT set_config('sauth.debug_private_key', :'sauth_debug_private_key', true);
SELECT set_config('sauth.debug_private_seed', :'sauth_debug_private_seed', true);
SELECT set_config('sauth.debug_client_secret', :'sauth_debug_client_secret', true);
SELECT set_config('claimius.replay_mode', 'true', true);

DO $$
DECLARE
    v_ctx                RECORD;
    v_user_claim_id      UUID;
    v_app_id             UUID;
    v_org_id             UUID;
    v_claim_id           UUID;
    v_type_id            UUID;
    v_bookable_id        UUID;
    v_timeslot_id        UUID;
    v_object_timeslot_id UUID;
    v_booking_id         UUID;
    v_timeslot_schedule  JSONB;
    v_booking_schedule   JSONB;
    v_start              TIMESTAMPTZ;
    v_end                TIMESTAMPTZ;
    v_hours              INT[] := ARRAY[8, 10, 12, 14, 16];
    v_day_idx            INT;
    v_hour_idx           INT;
    v_hour               INT;
    i                    INT;
BEGIN
    SELECT * INTO v_ctx FROM public.get_debug_context(current_setting('sauth.debug_user_id')::uuid);
    v_user_claim_id := v_ctx.user_claim_id;
    v_app_id        := v_ctx.app_id;
    v_org_id        := v_ctx.org_id;

    SELECT id INTO v_claim_id
      FROM claimius.claim
     WHERE app_id = v_app_id
       AND name = 'Debug Claim'
       AND sa_deleted_at IS NULL;

    IF v_claim_id IS NULL THEN
        RAISE EXCEPTION 'Debug activity fixture seed: Debug Claim not found.';
    END IF;

    IF (SELECT count(*) FROM booking
         WHERE name LIKE 'Debug Activity Booking %'
           AND sa_deleted_at IS NULL) >= 50 THEN
        RAISE NOTICE 'Debug activity fixture seed already populated.';
        RETURN;
    END IF;

    SELECT id INTO v_type_id
      FROM bookable_type
     WHERE name = 'Debug Activity Bookable Type'
       AND sa_deleted_at IS NULL;

    IF v_type_id IS NULL THEN
        v_type_id := gen_random_uuid();
        INSERT INTO bookable_type (
            id, name, description, sa_created_by, sa_owner_id
        ) VALUES (
            v_type_id,
            'Debug Activity Bookable Type', 'Debug activity fixture',
            v_user_claim_id, v_org_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_type_id,
            p_object_type   => 'public.bookable_type',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug activity fixture binding bookable_type'
        );
    END IF;

    SELECT id INTO v_bookable_id
      FROM bookable
     WHERE name = 'Debug Activity Bookable'
       AND sa_deleted_at IS NULL;

    IF v_bookable_id IS NULL THEN
        DECLARE
            v_activity_loc UUID;
        BEGIN
            SELECT id INTO v_activity_loc
              FROM claimius.location
             WHERE name = 'Debug HQ Room 1'
               AND sa_deleted_at IS NULL
             LIMIT 1;

            v_bookable_id := gen_random_uuid();
            INSERT INTO bookable (
                id, name, description, type_id, sa_location_id,
                sa_created_by, sa_owner_id
            ) VALUES (
                v_bookable_id,
                'Debug Activity Bookable', 'Debug activity fixture',
                v_type_id, v_activity_loc,
                v_user_claim_id, v_org_id
            );
        END;

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_bookable_id,
            p_object_type   => 'public.bookable',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug activity fixture binding bookable'
        );
    END IF;

    SELECT id INTO v_timeslot_id
      FROM timeslot
     WHERE name = 'Debug Activity Timeslot'
       AND sa_deleted_at IS NULL;

    IF v_timeslot_id IS NULL THEN
        v_timeslot_id := gen_random_uuid();
        v_timeslot_schedule := jsonb_build_object(
            'id',         gen_random_uuid(),
            'start_date', '2026-05-04T00:00:00Z',
            'time_zone',  'UTC',
            'available',  true,
            'pattern', jsonb_build_object(
                'type', 'daily',
                'interval', 1,
                'days_of_week', jsonb_build_array(0, 1, 2, 3, 4, 5, 6),
                'times', jsonb_build_array('00:00/PT24H')
            )
        );

        INSERT INTO timeslot (
            id, name, description, schedule,
            sa_created_by, sa_owner_id
        ) VALUES (
            v_timeslot_id,
            'Debug Activity Timeslot',
            'Debug activity fixture covering all hours every day',
            v_timeslot_schedule,
            v_user_claim_id, v_org_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_timeslot_id,
            p_object_type   => 'public.timeslot',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug activity fixture binding timeslot'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM object_timeslot
         WHERE timeslot_id = v_timeslot_id
           AND object_id   = v_bookable_id
           AND object_type = 'public.bookable'
           AND sa_deleted_at IS NULL
    ) THEN
        v_object_timeslot_id := gen_random_uuid();
        INSERT INTO object_timeslot (
            id, reason, timeslot_id, object_id, priority,
            object_type, sa_created_by, sa_owner_id
        ) VALUES (
            v_object_timeslot_id,
            'Debug activity fixture',
            v_timeslot_id, v_bookable_id, 1,
            'public.bookable',
            v_user_claim_id, v_org_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_object_timeslot_id,
            p_object_type   => 'public.object_timeslot',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug activity fixture binding object_timeslot'
        );
    END IF;

    FOR i IN 1..50 LOOP
        v_day_idx  := ((i - 1) / 5) + 1;
        v_hour_idx := ((i - 1) % 5) + 1;
        v_hour     := v_hours[v_hour_idx];
        v_start    := (DATE '2026-05-05' + (v_day_idx - 1))::timestamptz
                       + (v_hour || ' hours')::interval;
        v_end      := v_start + interval '1 hour';

        v_booking_schedule := jsonb_build_object(
            'id',         gen_random_uuid(),
            'start_date', to_jsonb(v_start),
            'end_date',   to_jsonb(v_end),
            'time_zone',  'UTC',
            'available',  true,
            'pattern', jsonb_build_object(
                'type',     'none',
                'interval', 1
            )
        );

        v_booking_id := gen_random_uuid();
        INSERT INTO booking (
            id, name, description, bookable_id, schedule,
            sa_created_by, sa_owner_id
        ) VALUES (
            v_booking_id,
            'Debug Activity Booking ' || lpad(i::text, 2, '0'),
            'Debug activity fixture',
            v_bookable_id, v_booking_schedule,
            v_user_claim_id, v_org_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_booking_id,
            p_object_type   => 'public.booking',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug activity fixture binding booking ' || i
        );
    END LOOP;

    RAISE NOTICE 'Inserted Debug activity fixture: bookable_type, bookable, timeslot, object_timeslot, and 50 bookings.';
END $$;

DO $$
DECLARE
    v_ctx                RECORD;
    v_user_claim_id      UUID;
    v_app_id             UUID;
    v_org_id             UUID;
    v_claim_id           UUID;
    v_bookable_id        UUID;
    v_booking_id         UUID;
    v_checkin_id         UUID;
    v_booking_schedule   JSONB;
    v_now                TIMESTAMPTZ := now();
    v_start              TIMESTAMPTZ;
    v_end                TIMESTAMPTZ;
    v_days_back          INT;
    v_hour               INT;
    v_use_checkin        BOOLEAN;
    v_checkin_kind       INT;
    v_check_in           TIMESTAMPTZ;
    v_check_out          TIMESTAMPTZ;
    i                    INT;
BEGIN
    SELECT * INTO v_ctx FROM public.get_debug_context(current_setting('sauth.debug_user_id')::uuid);
    v_user_claim_id := v_ctx.user_claim_id;
    v_app_id        := v_ctx.app_id;
    v_org_id        := v_ctx.org_id;

    SELECT id INTO v_claim_id
      FROM claimius.claim
     WHERE app_id = v_app_id
       AND name = 'Debug Claim'
       AND sa_deleted_at IS NULL;

    IF v_claim_id IS NULL THEN
        RAISE EXCEPTION 'Debug activity history seed: Debug Claim not found.';
    END IF;

    SELECT id INTO v_bookable_id
      FROM bookable
     WHERE name = 'Debug Activity Bookable'
       AND sa_deleted_at IS NULL;

    IF v_bookable_id IS NULL THEN
        RAISE EXCEPTION 'Debug activity history seed: Debug Activity Bookable not found.';
    END IF;

    IF (SELECT count(*) FROM booking
         WHERE name LIKE 'Debug Activity History Booking %'
           AND sa_deleted_at IS NULL) >= 60 THEN
        RAISE NOTICE 'Debug activity history seed already populated.';
        RETURN;
    END IF;

    FOR i IN 1..60 LOOP
        v_days_back   := i;
        v_hour        := 8 + ((i - 1) % 9);
        v_start       := date_trunc('day', v_now - (v_days_back || ' days')::interval)
                          + (v_hour || ' hours')::interval;
        v_end         := v_start + interval '1 hour';

        v_use_checkin := (i % 2 = 0);
        v_checkin_id  := NULL;

        IF v_use_checkin THEN
            v_checkin_kind := ((i / 2) % 3);
            v_checkin_id   := gen_random_uuid();

            INSERT INTO checkin (
                id, starts_at, ends_at, object_type, object_id,
                type, sa_created_by, sa_owner_id
            ) VALUES (
                v_checkin_id,
                v_start, v_end,
                'public.bookable', v_bookable_id,
                'manual',
                v_user_claim_id, v_org_id
            );

            PERFORM claimius.assign_claim_object(
                p_app_id        => v_app_id,
                p_claim_id      => v_claim_id,
                p_object_id     => v_checkin_id,
                p_object_type   => 'public.checkin',
                p_sa_owner_id   => v_org_id,
                p_sa_root_id    => v_org_id,
                p_sa_created_by => v_user_claim_id,
                p_sa_access     => 15,
                p_inherits      => TRUE,
                p_reason        => 'Debug activity history binding checkin ' || i
            );

            IF v_checkin_kind = 0 THEN
                v_check_in  := v_start + interval '2 minutes';
                v_check_out := v_end - interval '5 minutes';
                UPDATE checkin SET check_in = v_check_in WHERE id = v_checkin_id;
                UPDATE checkin SET check_out = v_check_out WHERE id = v_checkin_id;
            ELSIF v_checkin_kind = 1 THEN
                v_check_in := v_start + interval '3 minutes';
                UPDATE checkin SET check_in = v_check_in WHERE id = v_checkin_id;
            END IF;
        END IF;

        v_booking_schedule := jsonb_build_object(
            'id',         gen_random_uuid(),
            'start_date', to_jsonb(v_start),
            'end_date',   to_jsonb(v_end),
            'time_zone',  'UTC',
            'available',  true,
            'pattern', jsonb_build_object(
                'type',     'none',
                'interval', 1
            )
        );

        v_booking_id := gen_random_uuid();
        INSERT INTO booking (
            id, name, description, bookable_id, schedule, checkin_id,
            sa_created_by, sa_owner_id
        ) VALUES (
            v_booking_id,
            'Debug Activity History Booking ' || lpad(i::text, 2, '0'),
            'Debug activity history fixture (' || v_days_back || 'd ago)',
            v_bookable_id, v_booking_schedule, v_checkin_id,
            v_user_claim_id, v_org_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_booking_id,
            p_object_type   => 'public.booking',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug activity history binding booking ' || i
        );
    END LOOP;

    RAISE NOTICE 'Inserted Debug activity history fixture: 60 past bookings (30 with checkin lifecycle). Activity promoter will backfill booking_ended and checkin_failed on server start.';
END $$;

DO $$
DECLARE
    v_ctx                    RECORD;
    v_user_claim_id          UUID;
    v_app_id                 UUID;
    v_org_id                 UUID;
    v_claim_id               UUID;
    v_capability_id          UUID;
    v_object_capability_id   UUID;
    v_bookable_record        RECORD;
    v_oc_priority            INT;
    v_oc_reason              TEXT;
    v_oc_index               INT := 0;
BEGIN
    SELECT * INTO v_ctx FROM public.get_debug_context(current_setting('sauth.debug_user_id')::uuid);
    v_user_claim_id := v_ctx.user_claim_id;
    v_app_id        := v_ctx.app_id;
    v_org_id        := v_ctx.org_id;

    SELECT id INTO v_claim_id
      FROM claimius.claim
     WHERE app_id = v_app_id
       AND name = 'Debug Claim'
       AND sa_deleted_at IS NULL;

    IF v_claim_id IS NULL THEN
        RAISE EXCEPTION 'Debug activity capacity seed: Debug Claim not found.';
    END IF;

    SELECT id INTO v_capability_id
      FROM capability
     WHERE name = 'Debug Activity Capacity Capability'
       AND sa_deleted_at IS NULL;

    IF v_capability_id IS NULL THEN
        v_capability_id := gen_random_uuid();
        INSERT INTO capability (
            id, name, description, locale, value, render, sa_created_by, sa_owner_id
        ) VALUES (
            v_capability_id,
            'Debug Activity Capacity Capability',
            'Capacity capability for activity fixtures',
            jsonb_build_object(
                'name', jsonb_build_object('eng', 'Capacity', 'nob', 'Kapasitet')
            ),
            jsonb_build_object('capacity', 8),
            'capacity {{ path ".capacity" }}',
            v_user_claim_id, v_org_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_capability_id,
            p_object_type   => 'public.capability',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug activity capacity capability binding'
        );
    END IF;

    FOR v_bookable_record IN
        SELECT b.id AS bookable_id, b.sa_owner_id AS owner_id
          FROM bookable b
         WHERE (b.name = 'Debug Activity Bookable' OR b.name LIKE 'Debug Bookable %')
           AND b.sa_deleted_at IS NULL
         ORDER BY b.sa_created_at
         LIMIT 12
    LOOP
        IF EXISTS (
            SELECT 1 FROM object_capability oc
             WHERE oc.capability_id = v_capability_id
               AND oc.object_id = v_bookable_record.bookable_id
               AND oc.object_type = 'public.bookable'
               AND oc.sa_deleted_at IS NULL
        ) THEN
            CONTINUE;
        END IF;

        v_oc_index := v_oc_index + 1;

        v_oc_priority := CASE v_oc_index % 4
            WHEN 1 THEN 10
            WHEN 2 THEN 5
            WHEN 3 THEN 1
            ELSE 0
        END;

        v_oc_reason := CASE v_oc_index % 4
            WHEN 1 THEN 'High priority capacity override'
            WHEN 2 THEN 'Medium priority capacity override'
            WHEN 3 THEN 'Low priority capacity override'
            ELSE NULL
        END;

        v_object_capability_id := gen_random_uuid();
        INSERT INTO object_capability (
            id, reason, capability_id, object_id, priority,
            object_type, sa_created_by, sa_owner_id
        ) VALUES (
            v_object_capability_id,
            v_oc_reason,
            v_capability_id, v_bookable_record.bookable_id, v_oc_priority,
            'public.bookable',
            v_user_claim_id, v_bookable_record.owner_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_object_capability_id,
            p_object_type   => 'public.object_capability',
            p_sa_owner_id   => v_bookable_record.owner_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug activity capacity binding for bookable'
        );
    END LOOP;

    RAISE NOTICE 'Bound Debug Activity Capacity Capability to up to 12 bookables.';
END $$;

DO $$
DECLARE
    v_ctx                RECORD;
    v_user_claim_id      UUID;
    v_app_id             UUID;
    v_org_id             UUID;
    v_claim_id           UUID;
    v_bookable_ids       UUID[];
    v_bookable_owners    UUID[];
    v_bookable_count     INT;
    v_booking_id         UUID;
    v_checkin_id         UUID;
    v_booking_schedule   JSONB;
    v_now                TIMESTAMPTZ := now();
    v_start              TIMESTAMPTZ;
    v_end                TIMESTAMPTZ;
    v_days_back          INT;
    v_hour               INT;
    v_minute             INT;
    v_duration_min       INT;
    v_durations          INT[] := ARRAY[30, 60, 60, 60, 90, 120, 120, 180, 240];
    v_hours              INT[] := ARRAY[7, 8, 8, 9, 10, 11, 12, 13, 13, 14, 15, 15, 16, 17, 18, 19, 20];
    v_bookable_idx       INT;
    v_owner_id           UUID;
    v_bookable_id        UUID;
    v_checkin_kind       INT;
    v_check_in           TIMESTAMPTZ;
    v_check_out          TIMESTAMPTZ;
    i                    INT;
BEGIN
    SELECT * INTO v_ctx FROM public.get_debug_context(current_setting('sauth.debug_user_id')::uuid);
    v_user_claim_id := v_ctx.user_claim_id;
    v_app_id        := v_ctx.app_id;
    v_org_id        := v_ctx.org_id;

    SELECT id INTO v_claim_id
      FROM claimius.claim
     WHERE app_id = v_app_id
       AND name = 'Debug Claim'
       AND sa_deleted_at IS NULL;

    IF v_claim_id IS NULL THEN
        RAISE EXCEPTION 'Debug activity variety seed: Debug Claim not found.';
    END IF;

    IF (SELECT count(*) FROM booking
         WHERE name LIKE 'Debug Activity Variety Booking %'
           AND sa_deleted_at IS NULL) >= 300 THEN
        RAISE NOTICE 'Debug activity variety seed already populated.';
        RETURN;
    END IF;

    SELECT array_agg(b.id ORDER BY b.sa_created_at),
           array_agg(b.sa_owner_id ORDER BY b.sa_created_at)
      INTO v_bookable_ids, v_bookable_owners
      FROM bookable b
     WHERE b.name LIKE 'Debug Bookable %'
       AND b.sa_deleted_at IS NULL;

    v_bookable_count := coalesce(array_length(v_bookable_ids, 1), 0);

    IF v_bookable_count = 0 THEN
        RAISE EXCEPTION 'Debug activity variety seed: no Debug Bookable rows found.';
    END IF;

    FOR i IN 1..300 LOOP
        v_bookable_idx := ((i - 1) % v_bookable_count) + 1;
        v_bookable_id  := v_bookable_ids[v_bookable_idx];
        v_owner_id     := v_bookable_owners[v_bookable_idx];

        v_days_back    := 1 + ((i * 7 + v_bookable_idx) % 90);
        v_hour         := v_hours[((i * 13 + v_bookable_idx) % array_length(v_hours, 1)) + 1];
        v_minute       := (i % 4) * 15;
        v_duration_min := v_durations[((i * 17 + v_bookable_idx) % array_length(v_durations, 1)) + 1];

        v_start        := date_trunc('day', v_now - (v_days_back || ' days')::interval)
                          + (v_hour || ' hours')::interval
                          + (v_minute || ' minutes')::interval;
        v_end          := v_start + (v_duration_min || ' minutes')::interval;

        v_checkin_kind := i % 4;
        v_checkin_id   := NULL;

        IF v_checkin_kind <> 3 THEN
            v_checkin_id := gen_random_uuid();
            INSERT INTO checkin (
                id, starts_at, ends_at, object_type, object_id,
                type, sa_created_by, sa_owner_id
            ) VALUES (
                v_checkin_id,
                v_start, v_end,
                'public.bookable', v_bookable_id,
                CASE WHEN i % 2 = 0 THEN 'manual' ELSE 'auto' END,
                v_user_claim_id, v_owner_id
            );

            PERFORM claimius.assign_claim_object(
                p_app_id        => v_app_id,
                p_claim_id      => v_claim_id,
                p_object_id     => v_checkin_id,
                p_object_type   => 'public.checkin',
                p_sa_owner_id   => v_owner_id,
                p_sa_root_id    => v_org_id,
                p_sa_created_by => v_user_claim_id,
                p_sa_access     => 15,
                p_inherits      => TRUE,
                p_reason        => 'Debug activity variety binding checkin ' || i
            );

            IF v_checkin_kind = 0 THEN
                v_check_in  := v_start + ((i % 7) || ' minutes')::interval;
                v_check_out := v_end - ((i % 11) || ' minutes')::interval;
                UPDATE checkin SET check_in = v_check_in WHERE id = v_checkin_id;
                UPDATE checkin SET check_out = v_check_out WHERE id = v_checkin_id;
            ELSIF v_checkin_kind = 1 THEN
                v_check_in := v_start + ((i % 13) || ' minutes')::interval;
                UPDATE checkin SET check_in = v_check_in WHERE id = v_checkin_id;
            END IF;
        END IF;

        v_booking_schedule := jsonb_build_object(
            'id',         gen_random_uuid(),
            'start_date', to_jsonb(v_start),
            'end_date',   to_jsonb(v_end),
            'time_zone',  'UTC',
            'available',  true,
            'pattern', jsonb_build_object(
                'type',     'none',
                'interval', 1
            )
        );

        v_booking_id := gen_random_uuid();
        INSERT INTO booking (
            id, name, description, bookable_id, schedule, checkin_id,
            sa_created_by, sa_owner_id
        ) VALUES (
            v_booking_id,
            'Debug Activity Variety Booking ' || lpad(i::text, 3, '0'),
            'Debug activity variety fixture ('
                || v_days_back || 'd ago, '
                || v_duration_min || 'm, kind '
                || v_checkin_kind || ')',
            v_bookable_id, v_booking_schedule, v_checkin_id,
            v_user_claim_id, v_owner_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_booking_id,
            p_object_type   => 'public.booking',
            p_sa_owner_id   => v_owner_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug activity variety binding booking ' || i
        );
    END LOOP;

    RAISE NOTICE 'Inserted Debug activity variety fixture: 300 past bookings spread across all bookables, with mixed checkin states (complete/arrival-only/no-show/none). Activity promoter backfills booking_ended and checkin_failed on server start.';
END $$;
