SELECT set_config('sauth.debug_user_id', :'sauth_debug_user_id', true);
SELECT set_config('sauth.app_slug', :'sauth_app_slug', true);
SELECT set_config('sauth.debug_private_key', :'sauth_debug_private_key', true);
SELECT set_config('sauth.debug_private_seed', :'sauth_debug_private_seed', true);
SELECT set_config('sauth.debug_client_secret', :'sauth_debug_client_secret', true);
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
        RAISE EXCEPTION 'bookable_type seed: Debug Claim not found.';
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
        RAISE EXCEPTION 'bookable_type seed: expected 5 tier 1 orgs, found %.',
            coalesce(array_length(v_t1_ids, 1), 0);
    END IF;

    IF v_t2_ids IS NULL OR array_length(v_t2_ids, 1) < 10 THEN
        RAISE EXCEPTION 'bookable_type seed: expected 10 tier 2 orgs, found %.',
            coalesce(array_length(v_t2_ids, 1), 0);
    END IF;

    v_owners := ARRAY[
        v_org_id, v_org_id, v_org_id, v_org_id,
        v_t1_ids[1], v_t1_ids[2], v_t1_ids[3], v_t1_ids[4],
        v_t2_ids[1], v_t2_ids[2]
    ];

    IF (SELECT count(*) FROM bookable_type
         WHERE name LIKE 'Debug Type %'
           AND sa_deleted_at IS NULL) >= 15 THEN
        RAISE NOTICE 'bookable_type debug seed already populated.';
        RETURN;
    END IF;

    FOR i IN 1..10 LOOP
        IF EXISTS (
            SELECT 1 FROM bookable_type
             WHERE name = 'Debug Type ' || i
               AND sa_deleted_at IS NULL
        ) THEN
            CONTINUE;
        END IF;

        v_new_id := gen_random_uuid();
        INSERT INTO bookable_type (
            id, name, description, keywords,
            sa_created_by, sa_owner_id
        ) VALUES (
            v_new_id,
            'Debug Type ' || i, 'Bookable type ' || i,
            ARRAY['debug', 'type-' || i, 'tag-' || (i % 3)],
            v_user_claim_id, v_owners[i]
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'public.bookable_type',
            p_sa_owner_id   => v_owners[i],
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding bookable_type ' || i
        );
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM bookable_type WHERE name = 'Debug Type 11' AND sa_deleted_at IS NULL) THEN
        v_new_id := gen_random_uuid();
        INSERT INTO bookable_type (id, name, description, keywords, sa_created_by, sa_owner_id)
        VALUES (v_new_id, 'Debug Type 11', 'Conference room',
                ARRAY['debug','conference','meeting'], v_user_claim_id, v_org_id);
        PERFORM claimius.assign_claim_object(
            p_app_id => v_app_id, p_claim_id => v_claim_id, p_object_id => v_new_id,
            p_object_type => 'public.bookable_type', p_sa_owner_id => v_org_id,
            p_sa_root_id => v_org_id, p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits => TRUE, p_reason => 'Debug claim binding Debug Type 11'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM bookable_type WHERE name = 'Debug Type 12' AND sa_deleted_at IS NULL) THEN
        v_new_id := gen_random_uuid();
        INSERT INTO bookable_type (id, name, description, keywords, sa_created_by, sa_owner_id)
        VALUES (v_new_id, 'Debug Type 12', 'Hot desk',
                ARRAY['debug','desk','flexi'], v_user_claim_id, v_t1_ids[1]);
        PERFORM claimius.assign_claim_object(
            p_app_id => v_app_id, p_claim_id => v_claim_id, p_object_id => v_new_id,
            p_object_type => 'public.bookable_type', p_sa_owner_id => v_t1_ids[1],
            p_sa_root_id => v_org_id, p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits => TRUE, p_reason => 'Debug claim binding Debug Type 12'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM bookable_type WHERE name = 'Debug Type 13' AND sa_deleted_at IS NULL) THEN
        v_new_id := gen_random_uuid();
        INSERT INTO bookable_type (id, name, description, keywords, sa_created_by, sa_owner_id)
        VALUES (v_new_id, 'Debug Type 13', 'Parking spot',
                ARRAY['debug','parking','car'], v_user_claim_id, v_t1_ids[2]);
        PERFORM claimius.assign_claim_object(
            p_app_id => v_app_id, p_claim_id => v_claim_id, p_object_id => v_new_id,
            p_object_type => 'public.bookable_type', p_sa_owner_id => v_t1_ids[2],
            p_sa_root_id => v_org_id, p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits => TRUE, p_reason => 'Debug claim binding Debug Type 13'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM bookable_type WHERE name = 'Debug Type 14' AND sa_deleted_at IS NULL) THEN
        v_new_id := gen_random_uuid();
        INSERT INTO bookable_type (id, name, description, keywords, sa_created_by, sa_owner_id)
        VALUES (v_new_id, 'Debug Type 14', 'Outdoor area',
                ARRAY['debug','outdoor','garden'], v_user_claim_id, v_t2_ids[1]);
        PERFORM claimius.assign_claim_object(
            p_app_id => v_app_id, p_claim_id => v_claim_id, p_object_id => v_new_id,
            p_object_type => 'public.bookable_type', p_sa_owner_id => v_t2_ids[1],
            p_sa_root_id => v_org_id, p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits => TRUE, p_reason => 'Debug claim binding Debug Type 14'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM bookable_type WHERE name = 'Debug Type 15' AND sa_deleted_at IS NULL) THEN
        v_new_id := gen_random_uuid();
        INSERT INTO bookable_type (id, name, description, keywords, sa_created_by, sa_owner_id)
        VALUES (v_new_id, 'Debug Type 15', 'Sports facility',
                ARRAY['debug','sports','gym'], v_user_claim_id, v_t2_ids[2]);
        PERFORM claimius.assign_claim_object(
            p_app_id => v_app_id, p_claim_id => v_claim_id, p_object_id => v_new_id,
            p_object_type => 'public.bookable_type', p_sa_owner_id => v_t2_ids[2],
            p_sa_root_id => v_org_id, p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits => TRUE, p_reason => 'Debug claim binding Debug Type 15'
        );
    END IF;

    RAISE NOTICE 'Inserted 15 bookable_type rows for debug user across hierarchy.';
END $$;
