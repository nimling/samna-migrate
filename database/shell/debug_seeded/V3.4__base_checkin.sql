SELECT set_config('sauth.app_slug', :'sauth_app_slug', true);
SELECT set_config('sauth.debug_private_key', :'sauth_debug_private_key', true);
SELECT set_config('sauth.debug_private_seed', :'sauth_debug_private_seed', true);
SELECT set_config(
    'sauth.debug_user_id',
    convert_from(decode(:'sauth_debug_clients_b64', 'base64'), 'UTF8')::jsonb -> 'seeded' ->> 'client_id',
    true
);
SELECT set_config(
    'sauth.debug_client_secret',
    convert_from(decode(:'sauth_debug_clients_b64', 'base64'), 'UTF8')::jsonb -> 'seeded' ->> 'client_secret',
    true
);
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
    v_now              TIMESTAMPTZ := now();
    v_starts           TIMESTAMPTZ[];
    v_ends             TIMESTAMPTZ[];
    v_check_ins        TIMESTAMPTZ[];
    v_check_outs       TIMESTAMPTZ[];
    v_types            TEXT[];
    v_new_id           UUID;
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
        RAISE EXCEPTION 'checkin seed: Debug Claim not found.';
    END IF;

    SELECT array_agg(id ORDER BY sa_created_at),
           array_agg(sa_owner_id ORDER BY sa_created_at)
      INTO v_bookable_ids, v_bookable_owners
      FROM bookable
     WHERE name LIKE 'Debug Bookable %'
       AND sa_deleted_at IS NULL;

    IF v_bookable_ids IS NULL OR array_length(v_bookable_ids, 1) < 5 THEN
        RAISE EXCEPTION 'checkin seed: expected at least 5 debug bookables, found %.',
            coalesce(array_length(v_bookable_ids, 1), 0);
    END IF;

    IF (SELECT count(*) FROM checkin
         WHERE object_type = 'public.bookable'
           AND object_id = ANY(v_bookable_ids)
           AND sa_deleted_at IS NULL) >= 5 THEN
        RAISE NOTICE 'checkin debug seed already populated.';
        RETURN;
    END IF;

    v_starts := ARRAY[
        v_now - INTERVAL '15 minutes',
        v_now - INTERVAL '30 minutes',
        v_now + INTERVAL '10 minutes',
        v_now - INTERVAL '2 hours',
        v_now
    ];
    v_ends := ARRAY[
        v_now + INTERVAL '45 minutes',
        v_now + INTERVAL '90 minutes',
        v_now + INTERVAL '70 minutes',
        v_now - INTERVAL '1 hour',
        v_now + INTERVAL '60 minutes'
    ];
    v_check_ins := ARRAY[
        NULL::TIMESTAMPTZ,
        v_now - INTERVAL '20 minutes',
        NULL::TIMESTAMPTZ,
        v_now - INTERVAL '110 minutes',
        NULL::TIMESTAMPTZ
    ];
    v_check_outs := ARRAY[
        NULL::TIMESTAMPTZ,
        NULL::TIMESTAMPTZ,
        NULL::TIMESTAMPTZ,
        v_now - INTERVAL '70 minutes',
        NULL::TIMESTAMPTZ
    ];
    v_types := ARRAY['manual', 'auto', 'manual', 'auto', 'manual'];

    FOR i IN 1..5 LOOP
        v_new_id := gen_random_uuid();
        INSERT INTO checkin (
            id, starts_at, ends_at, object_type, object_id,
            check_in, check_out, type, sa_owner_id, sa_created_by
        ) VALUES (
            v_new_id,
            v_starts[i], v_ends[i],
            'public.bookable', v_bookable_ids[i],
            v_check_ins[i], v_check_outs[i], v_types[i],
            v_bookable_owners[i], v_user_claim_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'public.checkin',
            p_sa_owner_id   => v_bookable_owners[i],
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding checkin ' || i
        );
    END LOOP;

    RAISE NOTICE 'Inserted 5 realistic checkin rows for debug user (in-window, ongoing, upcoming, completed, opening-now).';
END $$;
