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
    v_secret_id     UUID;
    i               INT;
BEGIN
    SELECT * INTO v_ctx FROM public.get_debug_context(current_setting('sauth.debug_user_id')::uuid);
    v_user_claim_id := v_ctx.user_claim_id;
    v_app_id        := v_ctx.app_id;
    v_org_id        := v_ctx.org_id;

    SELECT uc.claim_id INTO v_claim_id
      FROM claimius.user_claim uc
     WHERE uc.id = v_user_claim_id
       AND uc.sa_deleted_at IS NULL;

    IF v_claim_id IS NULL THEN
        RAISE EXCEPTION 'samna_secret seed: no claim_id for user_claim %', v_user_claim_id;
    END IF;

    IF (SELECT count(*) FROM claimius.samna_secret
         WHERE app_id = v_app_id
           AND key LIKE 'debug.secret.%'
           AND sa_deleted_at IS NULL) >= 10 THEN
        RAISE NOTICE 'claimius.samna_secret debug seed already populated.';
        RETURN;
    END IF;

    FOR i IN 1..10 LOOP
        v_secret_id := gen_random_uuid();
        INSERT INTO claimius.samna_secret (
            id, app_id, key, value, sa_owner_id, sa_created_by
        ) VALUES (
            v_secret_id, v_app_id,
            'debug.secret.' || i, 'value_' || i,
            v_org_id, v_user_claim_id
        );
        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_secret_id,
            p_object_type   => 'claimius.samna_secret',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE
        );
    END LOOP;

    RAISE NOTICE 'Inserted 10 claimius.samna_secret rows for debug user.';
END $$;
