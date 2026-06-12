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
    v_loc_root_id   UUID;
    v_floor_id      UUID;
    v_new_id        UUID;
    v_target_org    UUID;
    i               INT;
    j               INT;
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
        RAISE EXCEPTION 'location seed: Debug Claim not found.';
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
        RAISE EXCEPTION 'location seed: expected 5 tier 1 orgs, found %.',
            coalesce(array_length(v_t1_ids, 1), 0);
    END IF;

    IF v_t2_ids IS NULL OR array_length(v_t2_ids, 1) < 10 THEN
        RAISE EXCEPTION 'location seed: expected 10 tier 2 orgs, found %.',
            coalesce(array_length(v_t2_ids, 1), 0);
    END IF;

    IF (SELECT count(*) FROM claimius.location
         WHERE app_id = v_app_id
           AND name LIKE 'Debug %'
           AND sa_deleted_at IS NULL) >= 28 THEN
        RAISE NOTICE 'claimius.location debug seed already populated.';
        RETURN;
    END IF;

    v_loc_root_id := gen_random_uuid();
    INSERT INTO claimius.location (
        id, app_id, sa_owner_id, name,
        description, type, sa_level, sa_created_by
    ) VALUES (
        v_loc_root_id, v_app_id, v_org_id,
        'Debug HQ', 'Root debug location', 'building', 0, v_user_claim_id
    );

    PERFORM claimius.assign_claim_object(
        p_app_id        => v_app_id,
        p_claim_id      => v_claim_id,
        p_object_id     => v_loc_root_id,
        p_object_type   => 'claimius.location',
        p_sa_owner_id   => v_org_id,
        p_sa_root_id    => v_org_id,
        p_sa_created_by => v_user_claim_id,
        p_sa_access     => 15,
        p_inherits      => TRUE,
        p_reason        => 'Debug claim binding location HQ'
    );

    v_floor_id := gen_random_uuid();
    INSERT INTO claimius.location (
        id, app_id, sa_owner_id, sa_parent_id, name,
        description, type, sa_level, sa_created_by
    ) VALUES (
        v_floor_id, v_app_id, v_org_id, v_loc_root_id,
        'Debug HQ Floor 1', 'Floor 1', 'floor', 1, v_user_claim_id
    );

    PERFORM claimius.assign_claim_object(
        p_app_id        => v_app_id,
        p_claim_id      => v_claim_id,
        p_object_id     => v_floor_id,
        p_object_type   => 'claimius.location',
        p_sa_owner_id   => v_org_id,
        p_sa_root_id    => v_org_id,
        p_sa_created_by => v_user_claim_id,
        p_sa_access     => 15,
        p_inherits      => TRUE,
        p_reason        => 'Debug claim binding location HQ Floor 1'
    );

    FOR i IN 1..3 LOOP
        v_new_id := gen_random_uuid();
        INSERT INTO claimius.location (
            id, app_id, sa_owner_id, sa_parent_id, name,
            description, type, longitude, latitude, sa_level, sa_created_by
        ) VALUES (
            v_new_id, v_app_id, v_org_id, v_floor_id,
            'Debug HQ Room ' || i, 'HQ Room ' || i, 'room',
            10.75 + (i * 0.001), 59.91 + (i * 0.001),
            2, v_user_claim_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'claimius.location',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding location HQ Room ' || i
        );
    END LOOP;

    FOR i IN 1..2 LOOP
        v_new_id := gen_random_uuid();
        INSERT INTO claimius.location (
            id, app_id, sa_owner_id, sa_parent_id, name,
            description, type, longitude, latitude, sa_level, sa_created_by
        ) VALUES (
            v_new_id, v_app_id, v_org_id, v_loc_root_id,
            'Debug HQ Lobby ' || i, 'Lobby ' || i, 'room',
            10.74 + (i * 0.001), 59.92 + (i * 0.001),
            1, v_user_claim_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'claimius.location',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding location HQ Lobby ' || i
        );
    END LOOP;

    FOR i IN 1..4 LOOP
        v_target_org := v_t1_ids[i];
        v_loc_root_id := gen_random_uuid();
        INSERT INTO claimius.location (
            id, app_id, sa_owner_id, name,
            description, type, sa_level, sa_created_by
        ) VALUES (
            v_loc_root_id, v_app_id, v_target_org,
            'Debug Branch ' || i, 'Branch building ' || i, 'building',
            0, v_user_claim_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_loc_root_id,
            p_object_type   => 'claimius.location',
            p_sa_owner_id   => v_target_org,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding location Branch ' || i
        );

        FOR j IN 1..2 LOOP
            v_new_id := gen_random_uuid();
            INSERT INTO claimius.location (
                id, app_id, sa_owner_id, sa_parent_id, name,
                description, type, longitude, latitude, sa_level, sa_created_by
            ) VALUES (
                v_new_id, v_app_id, v_target_org, v_loc_root_id,
                'Debug Branch ' || i || ' Room ' || j,
                'Branch ' || i || ' Room ' || j, 'room',
                10.70 + (i * 0.01) + (j * 0.001),
                59.85 + (i * 0.01) + (j * 0.001),
                1, v_user_claim_id
            );

            PERFORM claimius.assign_claim_object(
                p_app_id        => v_app_id,
                p_claim_id      => v_claim_id,
                p_object_id     => v_new_id,
                p_object_type   => 'claimius.location',
                p_sa_owner_id   => v_target_org,
                p_sa_root_id    => v_org_id,
                p_sa_created_by => v_user_claim_id,
                p_sa_access     => 15,
                p_inherits      => TRUE,
                p_reason        => 'Debug claim binding location Branch ' || i || ' Room ' || j
            );
        END LOOP;
    END LOOP;

    v_target_org := v_t2_ids[1];
    v_loc_root_id := gen_random_uuid();
    INSERT INTO claimius.location (
        id, app_id, sa_owner_id, name,
        description, type, sa_level, sa_created_by
    ) VALUES (
        v_loc_root_id, v_app_id, v_target_org,
        'Debug Outpost', 'Tier 2 outpost', 'building', 0, v_user_claim_id
    );

    PERFORM claimius.assign_claim_object(
        p_app_id        => v_app_id,
        p_claim_id      => v_claim_id,
        p_object_id     => v_loc_root_id,
        p_object_type   => 'claimius.location',
        p_sa_owner_id   => v_target_org,
        p_sa_root_id    => v_org_id,
        p_sa_created_by => v_user_claim_id,
        p_sa_access     => 15,
        p_inherits      => TRUE,
        p_reason        => 'Debug claim binding location Outpost'
    );

    v_new_id := gen_random_uuid();
    INSERT INTO claimius.location (
        id, app_id, sa_owner_id, sa_parent_id, name,
        description, type, longitude, latitude, sa_level, sa_created_by
    ) VALUES (
        v_new_id, v_app_id, v_target_org, v_loc_root_id,
        'Debug Outpost Cabin', 'Tier 2 cabin', 'room',
        10.60, 59.80, 1, v_user_claim_id
    );

    PERFORM claimius.assign_claim_object(
        p_app_id        => v_app_id,
        p_claim_id      => v_claim_id,
        p_object_id     => v_new_id,
        p_object_type   => 'claimius.location',
        p_sa_owner_id   => v_target_org,
        p_sa_root_id    => v_org_id,
        p_sa_created_by => v_user_claim_id,
        p_sa_access     => 15,
        p_inherits      => TRUE,
        p_reason        => 'Debug claim binding location Outpost Cabin'
    );

    SELECT id INTO v_loc_root_id
      FROM claimius.location
     WHERE app_id = v_app_id
       AND name = 'Debug HQ'
       AND sa_deleted_at IS NULL
     LIMIT 1;

    IF v_loc_root_id IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM claimius.location
             WHERE app_id = v_app_id
               AND name = 'Debug HQ Floor 2'
               AND sa_deleted_at IS NULL
       ) THEN
        v_floor_id := gen_random_uuid();
        INSERT INTO claimius.location (
            id, app_id, sa_owner_id, sa_parent_id, name,
            description, type, sa_level, sa_created_by
        ) VALUES (
            v_floor_id, v_app_id, v_org_id, v_loc_root_id,
            'Debug HQ Floor 2', 'Floor 2', 'floor', 1, v_user_claim_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_floor_id,
            p_object_type   => 'claimius.location',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding location HQ Floor 2'
        );

        FOR i IN 1..4 LOOP
            v_new_id := gen_random_uuid();
            INSERT INTO claimius.location (
                id, app_id, sa_owner_id, sa_parent_id, name,
                description, type, longitude, latitude, sa_level, sa_created_by
            ) VALUES (
                v_new_id, v_app_id, v_org_id, v_floor_id,
                'Debug HQ Meeting Room ' || i,
                'HQ Floor 2 meeting room ' || i, 'room',
                10.75 + (i * 0.002), 59.91 + (i * 0.002),
                2, v_user_claim_id
            );

            PERFORM claimius.assign_claim_object(
                p_app_id        => v_app_id,
                p_claim_id      => v_claim_id,
                p_object_id     => v_new_id,
                p_object_type   => 'claimius.location',
                p_sa_owner_id   => v_org_id,
                p_sa_root_id    => v_org_id,
                p_sa_created_by => v_user_claim_id,
                p_sa_access     => 15,
                p_inherits      => TRUE,
                p_reason        => 'Debug claim binding location HQ Meeting Room ' || i
            );
        END LOOP;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM claimius.location
         WHERE app_id = v_app_id
           AND name = 'Debug Branch 5'
           AND sa_deleted_at IS NULL
    ) THEN
        v_target_org := v_t1_ids[5];
        v_loc_root_id := gen_random_uuid();
        INSERT INTO claimius.location (
            id, app_id, sa_owner_id, name,
            description, type, sa_level, sa_created_by
        ) VALUES (
            v_loc_root_id, v_app_id, v_target_org,
            'Debug Branch 5', 'Branch building 5', 'building', 0, v_user_claim_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_loc_root_id,
            p_object_type   => 'claimius.location',
            p_sa_owner_id   => v_target_org,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding location Branch 5'
        );

        FOR j IN 1..2 LOOP
            v_new_id := gen_random_uuid();
            INSERT INTO claimius.location (
                id, app_id, sa_owner_id, sa_parent_id, name,
                description, type, longitude, latitude, sa_level, sa_created_by
            ) VALUES (
                v_new_id, v_app_id, v_target_org, v_loc_root_id,
                'Debug Branch 5 Room ' || j,
                'Branch 5 Room ' || j, 'room',
                10.75 + (j * 0.001), 59.95 + (j * 0.001),
                1, v_user_claim_id
            );

            PERFORM claimius.assign_claim_object(
                p_app_id        => v_app_id,
                p_claim_id      => v_claim_id,
                p_object_id     => v_new_id,
                p_object_type   => 'claimius.location',
                p_sa_owner_id   => v_target_org,
                p_sa_root_id    => v_org_id,
                p_sa_created_by => v_user_claim_id,
                p_sa_access     => 15,
                p_inherits      => TRUE,
                p_reason        => 'Debug claim binding location Branch 5 Room ' || j
            );
        END LOOP;
    END IF;

    RAISE NOTICE 'Inserted 29 claimius.location rows with inline Debug Claim bindings.';
END $$;
