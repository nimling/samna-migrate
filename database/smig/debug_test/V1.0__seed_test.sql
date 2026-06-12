SELECT set_config('sauth.app_slug', :'sauth_app_slug', true);
SELECT set_config(
    'sauth.debug_clients_json',
    convert_from(decode(:'sauth_debug_clients_b64', 'base64'), 'UTF8'),
    true
);

DO $$
DECLARE
    v_clients     JSONB := current_setting('sauth.debug_clients_json', true)::jsonb;
    v_test        JSONB := v_clients -> 'test';
    v_app_id      UUID  := claimius.get_disciple_app_id();
    v_test_uuid   UUID;
    v_test_sec    TEXT;
    v_test_org_id UUID;
BEGIN
    IF v_test IS NULL THEN
        RAISE NOTICE 'SAUTH_DEBUG_CLIENTS has no "test" entry; skipping.';
        RETURN;
    END IF;

    v_test_uuid := (v_test ->> 'client_id')::uuid;
    v_test_sec  := v_test ->> 'client_secret';

    SELECT id INTO v_test_org_id
      FROM claimius.organization
     WHERE app_id        = v_app_id
       AND name          = 'Test'
       AND sa_level      = 0
       AND sa_deleted_at IS NULL
     LIMIT 1;

    IF v_test_org_id IS NULL THEN
        v_test_org_id := gen_random_uuid();
        INSERT INTO claimius.organization (
            id, app_id, name, type, sa_owner_id, sa_root_id, sa_level, sa_created_by
        ) VALUES (
            v_test_org_id, v_app_id, 'Test', 'company',
            v_test_org_id, v_test_org_id, 0, v_test_uuid
        );
    END IF;

    INSERT INTO claimius.samna_client (
        id, client_id, name, app_id, secret_hash, sa_owner_id, sa_created_by
    ) VALUES (
        v_test_uuid, v_test_uuid, 'Test Client', v_app_id,
        crypt(v_test_sec, gen_salt('bf')),
        v_test_org_id, v_test_uuid
    )
    ON CONFLICT (id) DO UPDATE SET
        secret_hash   = EXCLUDED.secret_hash,
        sa_updated_at = now();
END $$;
