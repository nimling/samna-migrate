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
    v_named_names   TEXT[]   := ARRAY[
        'Debug Owner','Debug Admin','Debug Write','Debug Update',
        'Debug Action','Debug Read','Debug Member','Debug Guest'
    ];
    v_named_descs   TEXT[]   := ARRAY[
        'Owner of entire debug org tree',
        'Admin on entire debug org tree',
        'Write access on entire debug org tree, satisfies create checks',
        'Update access on entire debug org tree',
        'Action only access on entire debug org tree',
        'Read only access on entire debug org tree',
        'Member access on entire debug org tree',
        'Guest access on entire debug org tree'
    ];
    v_claim_id      UUID;
    i               INT;
BEGIN
    SELECT * INTO v_ctx FROM public.get_debug_context(current_setting('sauth.debug_user_id')::uuid);
    v_user_claim_id := v_ctx.user_claim_id;
    v_app_id        := v_ctx.app_id;
    v_org_id        := v_ctx.org_id;

    IF NOT EXISTS (
        SELECT 1 FROM claimius.claim
         WHERE app_id = v_app_id
           AND name = 'Debug Claim'
           AND sa_deleted_at IS NULL
    ) THEN
        PERFORM claimius.create_claim(
            p_app_id          => v_app_id,
            p_name            => 'Debug Claim',
            p_description     => 'Single debug claim for all debug data',
            p_sa_access => 1,
            p_sa_owner_id     => v_org_id,
            p_sa_root_id      => v_org_id,
            p_sa_created_by   => v_user_claim_id,
            p_inherits        => TRUE,
            
            p_type            => 'user'
        );
        RAISE NOTICE 'Inserted Debug Claim for debug user.';
    END IF;

    FOR i IN 1..array_length(v_named_names, 1) LOOP
        IF EXISTS (
            SELECT 1 FROM claimius.claim
             WHERE app_id = v_app_id
               AND name = v_named_names[i]
               AND sa_deleted_at IS NULL
        ) THEN
            CONTINUE;
        END IF;

        v_claim_id := (claimius.create_claim(
            p_app_id          => v_app_id,
            p_name            => v_named_names[i],
            p_description     => v_named_descs[i],
            p_sa_access => CASE i WHEN 1 THEN 1 WHEN 2 THEN 1 WHEN 3 THEN 2 WHEN 4 THEN 2 WHEN 5 THEN 8 WHEN 6 THEN 4 WHEN 7 THEN 4 ELSE 0 END,
            p_sa_owner_id     => v_org_id,
            p_sa_root_id      => v_org_id,
            p_sa_created_by   => v_user_claim_id,
            p_inherits        => TRUE,
            
            p_type            => 'user'
        ) -> 'claim' ->> 'id')::UUID;

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_org_id,
            p_object_type   => 'claimius.organization',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => v_named_names[i] || ' bound to root debug org'
        );
    END LOOP;

    RAISE NOTICE 'Named access level claims seeded.';
END $$;
