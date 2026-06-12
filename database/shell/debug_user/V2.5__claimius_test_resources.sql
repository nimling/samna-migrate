SELECT set_config('sauth.debug_user_id', :'sauth_debug_user_id', true);
SELECT set_config('sauth.app_slug', :'sauth_app_slug', true);
SELECT set_config('sauth.debug_private_key', :'sauth_debug_private_key', true);
SELECT set_config('sauth.debug_private_seed', :'sauth_debug_private_seed', true);
SELECT set_config('sauth.debug_client_secret', :'sauth_debug_client_secret', true);
SELECT set_config('claimius.replay_mode', 'true', true);

DO $$
DECLARE
    v_ctx                    RECORD;
    v_user_claim_id          UUID;
    v_app_id                 UUID;
    v_org_id                 UUID;
    v_claim_id               UUID;
    v_test_resource_targets  TEXT[]    := ARRAY[
        'Debug Test Resource Read Only',
        'Debug Test Resource Write Only',
        'Debug Test Resource Execute Only',
        'Debug Test Resource Owner Only',
        'Debug Test Resource Deny Read',
        'Debug Test Resource Deny Write',
        'Debug Test Resource Deny All',
        'Debug Test Resource Deny On Cascade'
    ];
    v_test_resource_access   INTEGER[] := ARRAY[
        4,
        2,
        8,
        1,
        20,
        18,
        31,
        15
    ];
    v_test_resource_id       UUID;
    v_deny_target_idx        INT       := 8;
    v_deny_object_id         UUID;
    i                        INT;
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
        RAISE EXCEPTION 'test resources seed: Debug Claim not found.';
    END IF;

    IF (SELECT count(*) FROM claimius.organization
         WHERE app_id = v_app_id
           AND sa_root_id = v_org_id
           AND name LIKE 'Debug Test Resource %'
           AND sa_deleted_at IS NULL) >= array_length(v_test_resource_targets, 1) THEN
        RAISE NOTICE 'claimius.test_resources debug seed already populated.';
        RETURN;
    END IF;

    FOR i IN 1..array_length(v_test_resource_targets, 1) LOOP
        v_test_resource_id := gen_random_uuid();
        INSERT INTO claimius.organization (
            id, app_id, name, description, type,
            sa_owner_id, sa_level, sa_created_by
        ) VALUES (
            v_test_resource_id, v_app_id,
            v_test_resource_targets[i],
            'Test resource for bit setting ' || v_test_resource_access[i]::TEXT,
            'child',
            v_org_id, 1, v_user_claim_id
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_test_resource_id,
            p_object_type   => 'claimius.organization',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => v_test_resource_access[i],
            p_inherits      => FALSE,
            p_reason        => v_test_resource_targets[i] || ' (' || v_test_resource_access[i]::TEXT || ')'
        );

        IF i = v_deny_target_idx THEN
            v_deny_object_id := v_test_resource_id;
        END IF;
    END LOOP;

    PERFORM claimius.assign_claim_object(
        p_app_id        => v_app_id,
        p_claim_id      => v_claim_id,
        p_object_id     => v_deny_object_id,
        p_object_type   => 'claimius.organization',
        p_sa_owner_id   => v_org_id,
        p_sa_root_id    => v_org_id,
        p_sa_created_by => v_user_claim_id,
        p_sa_access     => 22,
        p_inherits      => FALSE,
        p_reason        => 'Debug Test Resource Deny On Cascade deny binding'
    );

    RAISE NOTICE 'Inserted % bit setting test resources for debug user.', array_length(v_test_resource_targets, 1);
END $$;
