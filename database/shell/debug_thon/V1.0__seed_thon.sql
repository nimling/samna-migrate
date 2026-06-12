SELECT set_config('sauth.app_slug', :'sauth_app_slug', true);
SELECT set_config(
    'sauth.debug_clients_json',
    convert_from(decode(:'sauth_debug_clients_b64', 'base64'), 'UTF8'),
    true
);

DO $$
DECLARE
    v_clients       JSONB := current_setting('sauth.debug_clients_json', true)::jsonb;
    v_thon          JSONB := v_clients -> 'thon';
    v_app_id        UUID  := claimius.get_disciple_app_id();
    v_thon_uuid     UUID;
    v_thon_sec      TEXT;
    v_thon_org_id   UUID;
    v_thon_claim_id UUID;
BEGIN
    IF v_thon IS NULL THEN
        RAISE NOTICE 'SAUTH_DEBUG_CLIENTS has no "thon" entry; skipping.';
        RETURN;
    END IF;

    v_thon_uuid := (v_thon ->> 'client_id')::uuid;
    v_thon_sec  := v_thon ->> 'client_secret';

    SELECT id INTO v_thon_org_id
      FROM claimius.organization
     WHERE app_id        = v_app_id
       AND name          = 'Thon'
       AND sa_level      = 0
       AND sa_deleted_at IS NULL
     LIMIT 1;

    IF v_thon_org_id IS NULL THEN
        v_thon_org_id := gen_random_uuid();
        INSERT INTO claimius.organization (
            id, app_id, name, type, sa_owner_id, sa_root_id, sa_level, sa_created_by
        ) VALUES (
            v_thon_org_id, v_app_id, 'Thon', 'company',
            v_thon_org_id, v_thon_org_id, 0, v_thon_uuid
        );
    END IF;

    PERFORM claimius.ensure_app_user(
        p_user_id    => v_thon_uuid,
        p_app_id     => v_app_id,
        p_first_name => 'Thon',
        p_last_name  => 'User',
        p_email      => 'thon@local'
    );

    SELECT id INTO v_thon_claim_id
      FROM claimius.claim
     WHERE app_id        = v_app_id
       AND name          = 'Owner'
       AND sa_owner_id   = v_thon_org_id
       AND sa_deleted_at IS NULL
     LIMIT 1;

    IF v_thon_claim_id IS NULL THEN
        v_thon_claim_id := (claimius.create_claim(
            p_app_id        => v_app_id,
            p_name          => 'Owner',
            p_description   => 'Owner of Thon organization',
            p_sa_access     => 1,
            p_sa_owner_id   => v_thon_org_id,
            p_sa_root_id    => v_thon_org_id,
            p_sa_created_by => v_thon_uuid
        ) -> 'claim' ->> 'id')::UUID;

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_thon_claim_id,
            p_object_id     => v_thon_org_id,
            p_object_type   => 'claimius.organization',
            p_sa_owner_id   => v_thon_org_id,
            p_sa_root_id    => v_thon_org_id,
            p_sa_created_by => v_thon_uuid,
            p_sa_access     => 15
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM claimius.user_claim
         WHERE app_id        = v_app_id
           AND claim_id      = v_thon_claim_id
           AND user_id       = v_thon_uuid
           AND sa_deleted_at IS NULL
    ) THEN
        PERFORM claimius.assign_claim_user(
            p_app_id        => v_app_id,
            p_claim_id      => v_thon_claim_id,
            p_user_id       => v_thon_uuid,
            p_sa_owner_id   => v_thon_org_id,
            p_sa_created_by => v_thon_uuid
        );
    END IF;

    INSERT INTO claimius.samna_client (
        id, client_id, name, app_id, secret_hash, sa_owner_id, sa_created_by
    ) VALUES (
        v_thon_uuid, v_thon_uuid, 'Thon Client', v_app_id,
        crypt(v_thon_sec, gen_salt('bf')),
        v_thon_org_id, v_thon_uuid
    )
    ON CONFLICT (id) DO UPDATE SET
        secret_hash   = EXCLUDED.secret_hash,
        sa_updated_at = now();
END $$;
