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
    v_debug_user_id UUID := current_setting('sauth.debug_user_id')::uuid;
    v_user_claim_id UUID;
    v_app_id        UUID;
    v_org_id        UUID;
    v_claim_id      UUID;
    v_named         RECORD;
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
        RAISE EXCEPTION 'user_claim seed: Debug Claim not found.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM claimius.user_claim
         WHERE user_id = v_debug_user_id
           AND app_id = v_app_id
           AND claim_id = v_claim_id
           AND sa_deleted_at IS NULL
    ) THEN
        PERFORM claimius.assign_claim_user(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_user_id       => v_debug_user_id,
            p_sa_owner_id   => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_reason        => 'Debug claim grant'
        );
        RAISE NOTICE 'Inserted claimius.user_claim row for debug user.';
    END IF;

    FOR v_named IN
        SELECT id, name FROM claimius.claim
         WHERE app_id = v_app_id
           AND name IN ('Debug Owner','Debug Admin','Debug Write','Debug Update',
                        'Debug Action','Debug Read','Debug Member','Debug Guest')
           AND sa_deleted_at IS NULL
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM claimius.user_claim
             WHERE user_id = v_debug_user_id
               AND app_id  = v_app_id
               AND claim_id = v_named.id
               AND sa_deleted_at IS NULL
        ) THEN
            PERFORM claimius.assign_claim_user(
                p_app_id        => v_app_id,
                p_claim_id      => v_named.id,
                p_user_id       => v_debug_user_id,
                p_sa_owner_id   => v_org_id,
                p_sa_created_by => v_user_claim_id,
                p_reason        => v_named.name || ' grant for debug user'
            );
        END IF;
    END LOOP;

    RAISE NOTICE 'Named access level claims assigned to debug user.';
END $$;
