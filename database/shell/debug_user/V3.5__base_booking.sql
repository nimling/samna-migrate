SELECT set_config('sauth.debug_user_id', :'sauth_debug_user_id', true);
SELECT set_config('sauth.app_slug', :'sauth_app_slug', true);
SELECT set_config('sauth.debug_private_key', :'sauth_debug_private_key', true);
SELECT set_config('sauth.debug_private_seed', :'sauth_debug_private_seed', true);
SELECT set_config('sauth.debug_client_secret', :'sauth_debug_client_secret', true);
SELECT set_config('claimius.replay_mode', 'true', true);

DO $$
DECLARE
    v_ctx              RECORD;
    v_user_claim_id    UUID;
    v_app_id           UUID;
    v_org_id           UUID;
    v_claim_id         UUID;
    v_bookable_ids     UUID[];
    v_bookable_owners  UUID[];
    v_checkin_count    INT;
    v_checkin_id       UUID;
    v_start            TIMESTAMPTZ;
    v_end              TIMESTAMPTZ;
    v_hour             INT;
    v_duration_h       INT;
    v_pattern          JSONB;
    v_schedule         JSONB;
    v_bookable_idx     INT;
    v_booking_idx      INT;
    v_new_id           UUID;
    v_now              TIMESTAMPTZ := now();
    i                  INT;
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
        RAISE EXCEPTION 'booking seed: Debug Claim not found.';
    END IF;

    SELECT array_agg(id ORDER BY sa_created_at),
           array_agg(sa_owner_id ORDER BY sa_created_at)
      INTO v_bookable_ids, v_bookable_owners
      FROM bookable
     WHERE name LIKE 'Debug Bookable %'
       AND sa_deleted_at IS NULL;

    SELECT count(*) INTO v_checkin_count
      FROM checkin
     WHERE object_type = 'public.bookable'
       AND object_id = ANY(v_bookable_ids)
       AND sa_deleted_at IS NULL;

    IF v_bookable_ids IS NULL OR array_length(v_bookable_ids, 1) < 20 THEN
        RAISE EXCEPTION 'booking seed: expected at least 20 debug bookables, found %.',
            coalesce(array_length(v_bookable_ids, 1), 0);
    END IF;

    IF v_checkin_count < 5 THEN
        RAISE EXCEPTION 'booking seed: expected at least 5 debug checkins, found %.',
            v_checkin_count;
    END IF;

    IF (SELECT count(*) FROM booking
         WHERE name LIKE 'Debug Booking %'
           AND sa_deleted_at IS NULL) >= 100 THEN
        RAISE NOTICE 'booking debug seed already populated.';
        RETURN;
    END IF;

    FOR i IN 1..100 LOOP
        v_bookable_idx := ((i - 1) % array_length(v_bookable_ids, 1)) + 1;
        v_booking_idx  := ((i - 1) / array_length(v_bookable_ids, 1)) + 1;
        v_hour         := 8 + ((v_bookable_idx - 1) % 6);

        IF v_booking_idx <= 4 THEN
            v_start := date_trunc('day', v_now + ((v_booking_idx * 3) || ' days')::interval);
            v_end   := v_start;
            v_duration_h := 2;

            v_pattern := jsonb_build_object(
                'type', 'none',
                'interval', 1,
                'times', jsonb_build_array(
                    lpad(v_hour::text, 2, '0') || ':00/PT' || v_duration_h || 'H'
                )
            );
        ELSE
            v_start := date_trunc('day', v_now + interval '14 days');
            v_end   := date_trunc('day', v_now + interval '42 days');
            v_hour  := 12 + ((v_bookable_idx - 1) % 6);
            v_duration_h := 1;

            v_pattern := jsonb_build_object(
                'type', 'weekly',
                'interval', 1,
                'days_of_week', jsonb_build_array(1, 2, 3, 4, 5),
                'times', jsonb_build_array(
                    lpad(v_hour::text, 2, '0') || ':00/PT' || v_duration_h || 'H'
                )
            );
        END IF;

        v_schedule := jsonb_build_object(
            'id', gen_random_uuid(),
            'start_date', to_jsonb(v_start),
            'end_date',   to_jsonb(v_end),
            'time_zone',  'Europe/Oslo',
            'available',  false,
            'pattern',    v_pattern
        );

        IF v_booking_idx = 1 THEN
            SELECT id INTO v_checkin_id
              FROM checkin
             WHERE object_type = 'public.bookable'
               AND object_id = v_bookable_ids[v_bookable_idx]
               AND sa_deleted_at IS NULL
             ORDER BY starts_at
             LIMIT 1;
        ELSE
            v_checkin_id := NULL;
        END IF;

        v_new_id := gen_random_uuid();
        INSERT INTO booking (
            id, name, description, bookable_id, schedule,
            checkin_id, sa_created_by, sa_owner_id
        ) VALUES (
            v_new_id,
            'Debug Booking ' || i,
            'Reservation ' || i || ' for bookable ' || v_bookable_idx
                || CASE WHEN v_booking_idx <= 4 THEN ' (single)' ELSE ' (weekly mon-fri)' END,
            v_bookable_ids[v_bookable_idx],
            v_schedule,
            v_checkin_id,
            v_user_claim_id, v_bookable_owners[v_bookable_idx]
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'public.booking',
            p_sa_owner_id   => v_bookable_owners[v_bookable_idx],
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding booking ' || i
        );
    END LOOP;

    RAISE NOTICE 'Inserted 100 booking rows for debug user.';
END $$;
