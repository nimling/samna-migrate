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
    v_ctx           RECORD;
    v_user_claim_id UUID;
    v_app_id        UUID;
    v_org_id        UUID;
    v_claim_id      UUID;
    v_t1_ids        UUID[];
    v_t2_ids        UUID[];
    v_owners        UUID[];
    v_new_id        UUID;
    v_schedule      JSONB;
    i               INT;
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
        RAISE EXCEPTION 'timeslot seed: Debug Claim not found.';
    END IF;

    SELECT array_agg(id ORDER BY sa_created_at) INTO v_t1_ids
      FROM claimius.organization
     WHERE app_id = v_app_id
       AND sa_root_id = v_org_id
       AND sa_level = 1
       AND name LIKE 'Debug Sub Org T1 %'
       AND sa_deleted_at IS NULL;

    SELECT array_agg(id ORDER BY sa_created_at) INTO v_t2_ids
      FROM claimius.organization
     WHERE app_id = v_app_id
       AND sa_root_id = v_org_id
       AND sa_level = 2
       AND name LIKE 'Debug Sub Org T2 %'
       AND sa_deleted_at IS NULL;

    IF v_t1_ids IS NULL OR array_length(v_t1_ids, 1) < 5 THEN
        RAISE EXCEPTION 'timeslot seed: expected 5 tier 1 orgs, found %.',
            coalesce(array_length(v_t1_ids, 1), 0);
    END IF;

    IF v_t2_ids IS NULL OR array_length(v_t2_ids, 1) < 10 THEN
        RAISE EXCEPTION 'timeslot seed: expected 10 tier 2 orgs, found %.',
            coalesce(array_length(v_t2_ids, 1), 0);
    END IF;

    v_owners := ARRAY[
        v_org_id, v_org_id, v_org_id, v_org_id,
        v_t1_ids[1], v_t1_ids[2], v_t1_ids[3], v_t1_ids[4],
        v_t2_ids[1], v_t2_ids[2]
    ];

    IF (SELECT count(*) FROM timeslot
         WHERE name LIKE 'Debug Timeslot %'
           AND sa_deleted_at IS NULL) >= 10 THEN
        RAISE NOTICE 'timeslot debug seed already populated.';
        RETURN;
    END IF;

    v_schedule := jsonb_build_object(
        'id',         gen_random_uuid(),
        'start_date', '2026-01-01T08:00:00Z',
        'end_date',   '2026-12-31T18:00:00Z',
        'time_zone',  'Europe/Oslo',
        'pattern', jsonb_build_object(
            'type', 'weekly',
            'interval', 1,
            'days_of_week', jsonb_build_array(1, 2, 3, 4, 5),
            'times', jsonb_build_array('08:00/PT10H')
        )
    );

    FOR i IN 1..10 LOOP
        v_new_id := gen_random_uuid();
        INSERT INTO timeslot (
            id, name, description, schedule,
            sa_created_by, sa_owner_id
        ) VALUES (
            v_new_id,
            'Debug Timeslot ' || i, 'Schedule slot ' || i,
            v_schedule,
            v_user_claim_id, v_owners[i]
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'public.timeslot',
            p_sa_owner_id   => v_owners[i],
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding timeslot ' || i
        );
    END LOOP;

    RAISE NOTICE 'Inserted 10 timeslot rows for debug user across hierarchy.';
END $$;
