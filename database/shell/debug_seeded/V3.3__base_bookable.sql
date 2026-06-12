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
    v_ctx             RECORD;
    v_debug_user_id   UUID := current_setting('sauth.debug_user_id')::uuid;
    v_user_claim_id   UUID;
    v_app_id          UUID;
    v_org_id          UUID;
    v_claim_id        UUID;
    v_t1_ids          UUID[];
    v_t2_ids          UUID[];
    v_hq_loc_ids      UUID[];
    v_branch_loc_ids  UUID[];
    v_outpost_loc_ids UUID[];
    v_type_ids        UUID[];
    v_timeslot_ids    UUID[];
    v_capability_ids  UUID[];
    v_new_id          UUID;
    v_object_id       UUID;
    v_target_loc      UUID;
    v_target_owner    UUID;
    i                 INT;
BEGIN
    SELECT * INTO v_ctx FROM public.get_debug_context(v_debug_user_id);
    v_user_claim_id := v_ctx.user_claim_id;
    v_app_id        := v_ctx.app_id;
    v_org_id        := v_ctx.org_id;

    SELECT id INTO v_claim_id
      FROM claimius.claim
     WHERE app_id = v_app_id
       AND name = 'Debug Claim'
       AND sa_deleted_at IS NULL;

    IF v_claim_id IS NULL THEN
        RAISE EXCEPTION 'bookable seed: Debug Claim not found.';
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

    SELECT array_agg(id ORDER BY sa_created_at) INTO v_hq_loc_ids
      FROM claimius.location
     WHERE app_id = v_app_id
       AND sa_owner_id = v_org_id
       AND name LIKE 'Debug HQ%'
       AND sa_deleted_at IS NULL;

    SELECT array_agg(l.id ORDER BY l.sa_created_at) INTO v_branch_loc_ids
      FROM claimius.location l
     WHERE l.app_id = v_app_id
       AND l.sa_owner_id = ANY(v_t1_ids)
       AND l.name LIKE 'Debug Branch%'
       AND l.sa_deleted_at IS NULL;

    SELECT array_agg(l.id ORDER BY l.sa_created_at) INTO v_outpost_loc_ids
      FROM claimius.location l
     WHERE l.app_id = v_app_id
       AND l.sa_owner_id = ANY(v_t2_ids)
       AND l.name LIKE 'Debug Outpost%'
       AND l.sa_deleted_at IS NULL;

    SELECT array_agg(id ORDER BY sa_created_at) INTO v_type_ids
      FROM bookable_type
     WHERE name LIKE 'Debug Type %'
       AND sa_deleted_at IS NULL;

    SELECT array_agg(id ORDER BY sa_created_at) INTO v_timeslot_ids
      FROM timeslot
     WHERE name LIKE 'Debug Timeslot %'
       AND sa_deleted_at IS NULL;

    SELECT array_agg(id ORDER BY sa_created_at) INTO v_capability_ids
      FROM capability
     WHERE name LIKE 'Debug Capability %'
       AND sa_deleted_at IS NULL;

    IF v_t1_ids IS NULL OR array_length(v_t1_ids, 1) < 5 THEN
        RAISE EXCEPTION 'bookable seed: expected 5 tier 1 orgs, found %.',
            coalesce(array_length(v_t1_ids, 1), 0);
    END IF;

    IF v_t2_ids IS NULL OR array_length(v_t2_ids, 1) < 10 THEN
        RAISE EXCEPTION 'bookable seed: expected 10 tier 2 orgs, found %.',
            coalesce(array_length(v_t2_ids, 1), 0);
    END IF;

    IF v_hq_loc_ids IS NULL OR array_length(v_hq_loc_ids, 1) < 5 THEN
        RAISE EXCEPTION 'bookable seed: expected at least 5 HQ locations, found %.',
            coalesce(array_length(v_hq_loc_ids, 1), 0);
    END IF;

    IF v_branch_loc_ids IS NULL OR array_length(v_branch_loc_ids, 1) < 8 THEN
        RAISE EXCEPTION 'bookable seed: expected at least 8 branch locations, found %.',
            coalesce(array_length(v_branch_loc_ids, 1), 0);
    END IF;

    IF v_type_ids IS NULL OR array_length(v_type_ids, 1) < 10 THEN
        RAISE EXCEPTION 'bookable seed: expected 10 debug bookable_types, found %.',
            coalesce(array_length(v_type_ids, 1), 0);
    END IF;

    IF v_timeslot_ids IS NULL OR array_length(v_timeslot_ids, 1) < 10 THEN
        RAISE EXCEPTION 'bookable seed: expected 10 debug timeslots, found %.',
            coalesce(array_length(v_timeslot_ids, 1), 0);
    END IF;

    IF v_capability_ids IS NULL OR array_length(v_capability_ids, 1) < 10 THEN
        RAISE EXCEPTION 'bookable seed: expected 10 debug capabilities, found %.',
            coalesce(array_length(v_capability_ids, 1), 0);
    END IF;

    IF (SELECT count(*) FROM bookable
         WHERE name LIKE 'Debug Bookable %'
           AND sa_deleted_at IS NULL) >= 30 THEN
        RAISE NOTICE 'bookable debug seed already populated.';
        RETURN;
    END IF;

    FOR i IN 1..30 LOOP
        IF EXISTS (
            SELECT 1 FROM bookable
             WHERE name = 'Debug Bookable ' || i
               AND sa_deleted_at IS NULL
        ) THEN
            CONTINUE;
        END IF;

        v_new_id := gen_random_uuid();

        IF i <= 8 THEN
            v_target_owner := v_org_id;
            v_target_loc   := v_hq_loc_ids[((i - 1) % array_length(v_hq_loc_ids, 1)) + 1];
        ELSIF i <= 14 THEN
            v_target_owner := v_t1_ids[((i - 9) % 5) + 1];
            v_target_loc   := v_branch_loc_ids[((i - 9) % array_length(v_branch_loc_ids, 1)) + 1];
        ELSIF i <= 17 THEN
            v_target_owner := v_t2_ids[((i - 15) % 10) + 1];
            IF v_outpost_loc_ids IS NOT NULL AND array_length(v_outpost_loc_ids, 1) > 0 THEN
                v_target_loc := v_outpost_loc_ids[((i - 15) % array_length(v_outpost_loc_ids, 1)) + 1];
            ELSE
                v_target_loc := NULL;
            END IF;
        ELSIF i <= 20 THEN
            v_target_owner := v_t1_ids[((i - 18) % 5) + 1];
            v_target_loc   := NULL;
        ELSIF i <= 25 THEN
            v_target_owner := v_t2_ids[((i - 21) % 10) + 3];
            v_target_loc   := v_branch_loc_ids[((i - 21) % array_length(v_branch_loc_ids, 1)) + 1];
        ELSE
            v_target_owner := v_org_id;
            v_target_loc   := v_hq_loc_ids[((i - 26) % array_length(v_hq_loc_ids, 1)) + 1];
        END IF;

        INSERT INTO bookable (
            id, name, description, sa_location_id,
            type_id, sa_created_by, sa_owner_id
        ) VALUES (
            v_new_id,
            'Debug Bookable ' || i, 'Reservable ' || i,
            v_target_loc,
            v_type_ids[((i - 1) % array_length(v_type_ids, 1)) + 1],
            v_user_claim_id, v_target_owner
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'public.bookable',
            p_sa_owner_id   => v_target_owner,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding bookable ' || i
        );

        v_object_id := gen_random_uuid();
        INSERT INTO object_timeslot (
            id, reason, timeslot_id, object_id, priority,
            object_type, conditions, sa_created_by, sa_owner_id
        ) VALUES (
            v_object_id,
            'Bind timeslot ' || i,
            v_timeslot_ids[((i - 1) % array_length(v_timeslot_ids, 1)) + 1],
            v_new_id,
            i, 'public.bookable',
            jsonb_build_object('min_duration', 60),
            v_user_claim_id, v_target_owner
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_object_id,
            p_object_type   => 'public.object_timeslot',
            p_sa_owner_id   => v_target_owner,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding object_timeslot ' || i
        );

        v_object_id := gen_random_uuid();
        INSERT INTO object_capability (
            id, reason, capability_id, object_id, priority,
            object_type, sa_created_by, sa_owner_id
        ) VALUES (
            v_object_id,
            'Capability binding ' || i,
            v_capability_ids[((i - 1) % array_length(v_capability_ids, 1)) + 1],
            v_new_id, i, 'public.bookable',
            v_user_claim_id, v_target_owner
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_object_id,
            p_object_type   => 'public.object_capability',
            p_sa_owner_id   => v_target_owner,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding object_capability ' || i
        );
    END LOOP;

    RAISE NOTICE 'Inserted 30 bookable rows with timeslot and capability bindings for debug user.';
END $$;
