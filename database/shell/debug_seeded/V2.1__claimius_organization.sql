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
    v_tier1_ids     UUID[] := ARRAY[]::UUID[];
    v_tier2_ids     UUID[] := ARRAY[]::UUID[];
    v_new_id        UUID;
    v_parent_id     UUID;
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
        RAISE EXCEPTION 'organization seed: Debug Claim not found.';
    END IF;

    IF (SELECT count(*) FROM claimius.organization
         WHERE sa_root_id = v_org_id
           AND id <> v_org_id
           AND name LIKE 'Debug Sub Org %'
           AND sa_deleted_at IS NULL) >= 20 THEN
        RAISE NOTICE 'claimius.organization debug seed already populated.';
        RETURN;
    END IF;

    FOR i IN 1..5 LOOP
        v_new_id := gen_random_uuid();
        INSERT INTO claimius.organization (
            id, app_id, name, description, type,
            sa_owner_id, sa_level, sa_created_by
        ) VALUES (
            v_new_id, v_app_id,
            'Debug Sub Org T1 ' || i,
            'Tier 1 child organization ' || i,
            'child',
            v_org_id, 1, v_user_claim_id
        );
        v_tier1_ids := array_append(v_tier1_ids, v_new_id);

        IF i = 1 THEN
            UPDATE claimius.claim
               SET sa_owner_id = v_new_id
             WHERE id = v_claim_id;
        END IF;

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'claimius.organization',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding org T1 ' || i
        );
    END LOOP;

    FOR i IN 1..10 LOOP
        v_new_id := gen_random_uuid();
        v_parent_id := v_tier1_ids[((i - 1) % 5) + 1];
        INSERT INTO claimius.organization (
            id, app_id, name, description, type,
            sa_owner_id, sa_level, sa_created_by
        ) VALUES (
            v_new_id, v_app_id,
            'Debug Sub Org T2 ' || i,
            'Tier 2 child organization ' || i,
            'child',
            v_parent_id, 2, v_user_claim_id
        );
        v_tier2_ids := array_append(v_tier2_ids, v_new_id);

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'claimius.organization',
            p_sa_owner_id   => v_parent_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding org T2 ' || i
        );
    END LOOP;

    FOR i IN 1..5 LOOP
        v_new_id := gen_random_uuid();
        v_parent_id := v_tier2_ids[i];
        INSERT INTO claimius.organization (
            id, app_id, name, description, type,
            sa_owner_id, sa_level, sa_created_by
        ) VALUES (
            v_new_id, v_app_id,
            'Debug Sub Org T3 ' || i,
            'Tier 3 child organization ' || i,
            'child',
            v_parent_id, 3, v_user_claim_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'claimius.organization',
            p_sa_owner_id   => v_parent_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding org T3 ' || i
        );
    END LOOP;

    RAISE NOTICE 'Inserted 20 claimius.organization rows with inline Debug Claim bindings.';
END $$;
