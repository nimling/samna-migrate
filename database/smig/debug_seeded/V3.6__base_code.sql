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
    v_ctx              RECORD;
    v_user_claim_id    UUID;
    v_app_id           UUID;
    v_org_id           UUID;
    v_claim_id         UUID;
    v_bookable_ids     UUID[];
    v_bookable_owners  UUID[];
    v_new_id           UUID;
    i                  INT;
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
        RAISE EXCEPTION 'code seed: Debug Claim not found.';
    END IF;

    SELECT array_agg(id ORDER BY sa_created_at),
           array_agg(sa_owner_id ORDER BY sa_created_at)
      INTO v_bookable_ids, v_bookable_owners
      FROM bookable
     WHERE name LIKE 'Debug Bookable %'
       AND sa_deleted_at IS NULL;

    IF v_bookable_ids IS NULL OR array_length(v_bookable_ids, 1) < 20 THEN
        RAISE EXCEPTION 'code seed: expected at least 20 debug bookables, found %.',
            coalesce(array_length(v_bookable_ids, 1), 0);
    END IF;

    IF (SELECT count(*) FROM code
         WHERE name LIKE 'Debug Code %'
           AND sa_deleted_at IS NULL) >= array_length(v_bookable_ids, 1) THEN
        RAISE NOTICE 'code debug seed already populated.';
        RETURN;
    END IF;

    FOR i IN 1..array_length(v_bookable_ids, 1) LOOP
        IF EXISTS (
            SELECT 1 FROM code
             WHERE name = 'Debug Code ' || i
               AND sa_deleted_at IS NULL
        ) THEN
            CONTINUE;
        END IF;

        v_new_id := gen_random_uuid();
        INSERT INTO code (
            id, value, data, styling, name, description,
            sa_created_by, sa_owner_id, expires_at
        ) VALUES (
            v_new_id,
            'DBG-' || lpad(i::text, 4, '0'),
            jsonb_build_object('seq', i),
            jsonb_build_object(
                'color', jsonb_build_object(
                    'foreground', '#ffffff',
                    'background', CASE i % 5
                        WHEN 0 THEN '#3d3ab6'
                        WHEN 1 THEN '#0f766e'
                        WHEN 2 THEN '#b91c1c'
                        WHEN 3 THEN '#a16207'
                        ELSE '#7e22ce'
                    END
                )
            ),
            'Debug Code ' || i, 'QR code ' || i,
            v_user_claim_id, v_bookable_owners[i],
            now() + INTERVAL '30 days'
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'public.code',
            p_sa_owner_id   => v_bookable_owners[i],
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding code ' || i
        );
    END LOOP;

    RAISE NOTICE 'Inserted % code rows for debug user.', array_length(v_bookable_ids, 1);
END $$;
