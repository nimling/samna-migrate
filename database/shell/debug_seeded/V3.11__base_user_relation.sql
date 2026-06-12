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
    v_ctx         RECORD;
    v_app_id      UUID;
    v_user_id     UUID;
    v_bookable_id UUID;
BEGIN
    SELECT * INTO v_ctx FROM public.get_debug_context(current_setting('sauth.debug_user_id')::uuid);
    v_app_id  := v_ctx.app_id;
    v_user_id := current_setting('sauth.debug_user_id')::uuid;

    SELECT id INTO v_bookable_id
      FROM bookable
     WHERE name = 'Debug Bookable 1'
       AND sa_deleted_at IS NULL
     LIMIT 1;

    IF v_bookable_id IS NULL THEN
        RAISE EXCEPTION 'user_relation seed: Debug Bookable 1 not found.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM claimius.user_relation
         WHERE app_id = v_app_id
           AND user_id = v_user_id
           AND object_type = 'public.bookable'
           AND object_id = v_bookable_id
           AND sa_deleted_at IS NULL
    ) THEN
        RAISE NOTICE 'user_relation debug seed already populated.';
        RETURN;
    END IF;

    INSERT INTO claimius.user_relation (
        app_id, user_id, description, object_type, object_id,
        pinned, priority, used_at
    ) VALUES (
        v_app_id, v_user_id,
        'Debug favourite bookable',
        'public.bookable', v_bookable_id,
        1, 1, now()
    );

    RAISE NOTICE 'Inserted 1 user_relation row for debug user against Debug Bookable 1.';
END $$;
