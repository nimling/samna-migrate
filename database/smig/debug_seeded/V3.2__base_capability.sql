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
    v_t1_ids           UUID[];
    v_t2_ids           UUID[];
    v_owners           UUID[];
    v_capability_ids   UUID[] := '{}';
    v_new_id           UUID;
    v_oc_id            UUID;
    v_locale           JSONB;
    v_value            JSONB;
    v_render           TEXT;
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
        RAISE EXCEPTION 'capability seed: Debug Claim not found.';
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
        RAISE EXCEPTION 'capability seed: expected 5 tier 1 orgs, found %.',
            coalesce(array_length(v_t1_ids, 1), 0);
    END IF;

    IF v_t2_ids IS NULL OR array_length(v_t2_ids, 1) < 10 THEN
        RAISE EXCEPTION 'capability seed: expected 10 tier 2 orgs, found %.',
            coalesce(array_length(v_t2_ids, 1), 0);
    END IF;

    v_owners := ARRAY[
        v_org_id, v_org_id, v_org_id, v_org_id,
        v_t1_ids[1], v_t1_ids[2], v_t1_ids[3], v_t1_ids[4],
        v_t2_ids[1], v_t2_ids[2]
    ];

    IF (SELECT count(*) FROM capability
         WHERE name LIKE 'Debug Capability %'
           AND sa_deleted_at IS NULL) >= 10 THEN
        RAISE NOTICE 'capability debug seed already populated.';
        RETURN;
    END IF;

    FOR i IN 1..10 LOOP
        v_new_id := gen_random_uuid();

        v_locale := CASE i
            WHEN 3 THEN NULL
            WHEN 4 THEN jsonb_build_object(
                'name',             jsonb_build_object('eng', 'Connector Capability', 'nob', 'Koblingsfunksjon'),
                'description',      jsonb_build_object('eng', 'Connector with deep jsonpath localization', 'nob', 'Kobling med dyp jsonpath lokalisering'),
                '.connector.brand', jsonb_build_object('eng', 'Stripe', 'nob', 'Stripe'),
                '.connector.mode',  jsonb_build_object('eng', 'live mode', 'nob', 'live modus')
            )
            WHEN 5 THEN jsonb_build_object(
                'name',          jsonb_build_object('eng', 'Fallback Capability', 'nob', 'Reservefunksjon'),
                '.missing.path', jsonb_build_object('eng', 'Translated text for an absent value path', 'nob', 'Oversatt tekst for en manglende verdisti')
            )
            WHEN 8 THEN jsonb_build_object(
                'name',         jsonb_build_object('eng', 'Multi line Capability', 'nob', 'Flerlinje funksjon'),
                'description',  jsonb_build_object('eng', 'Renders a multi line markdown body', 'nob', 'Gjengir flerlinje markdown'),
                '.unit_label',  jsonb_build_object('eng', 'minutes', 'nob', 'minutter')
            )
            ELSE jsonb_build_object(
                'name',         jsonb_build_object('eng', 'Debug Capability ' || i, 'nob', 'Feilsøkingsfunksjon ' || i),
                'description',  jsonb_build_object('eng', 'Capability ' || i, 'nob', 'Funksjon ' || i),
                '.unit_label',  jsonb_build_object('eng', 'minutes', 'nob', 'minutter')
            )
        END;

        v_value := CASE i
            WHEN 4 THEN jsonb_build_object(
                'connector', jsonb_build_object(
                    'brand', 'Stripe',
                    'mode',  'live',
                    'region', jsonb_build_object('code', 'EU', 'currency', 'EUR')
                ),
                'duration_minutes', i * 10
            )
            WHEN 5 THEN jsonb_build_object(
                'duration_minutes', i * 10,
                'unit_label', 'minutes'
            )
            WHEN 7 THEN jsonb_build_object(
                'detail_link', 'https://docs.example.com/capabilities/' || i,
                'duration_minutes', i * 10
            )
            ELSE jsonb_build_object(
                'duration_minutes', i * 10,
                'unit_label', 'minutes',
                'detail_link', 'https://docs.example.com/capabilities/' || i
            )
        END;

        v_render := CASE i
            WHEN 2 THEN NULL
            WHEN 3 THEN '**' || (i * 10)::text || ' minutes** plain row, no helpers'
            WHEN 4 THEN E'### {{ localize "name" "eng" }}\n\n' ||
                        'Brand: **{{ localize ".connector.brand" "eng" }}**, ' ||
                        'mode: {{ localize ".connector.mode" "nob" }}, ' ||
                        'region: {{ path ".connector.region.code" }} ({{ path ".connector.region.currency" }})'
            WHEN 5 THEN '> {{ localize ".missing.path" "eng" }}'
            WHEN 6 THEN '# {{ localize "name" "eng" }}'
            WHEN 7 THEN 'See: <{{ path ".detail_link" }}>'
            WHEN 8 THEN E'## {{ localize "name" "nob" }}\n\n' ||
                        E'Duration: **{{ path ".duration_minutes" }} {{ localize ".unit_label" "nob" }}**\n\n' ||
                        '[Open]({{ path ".detail_link" }})'
            ELSE '**' || (i * 10)::text || ' {{ localize ".unit_label" "eng" }}** ' ||
                 '[link]({{ path ".detail_link" }})'
        END;

        INSERT INTO capability (
            id, name, description, locale, value, render,
            sa_created_by, sa_owner_id
        ) VALUES (
            v_new_id,
            'Debug Capability ' || i,
            'Capability ' || i,
            v_locale, v_value, v_render,
            v_user_claim_id, v_owners[i]
        );

        v_capability_ids := array_append(v_capability_ids, v_new_id);

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_new_id,
            p_object_type   => 'public.capability',
            p_sa_owner_id   => v_owners[i],
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding capability ' || i
        );
    END LOOP;

    FOR i IN 1..4 LOOP
        v_oc_id := gen_random_uuid();
        INSERT INTO object_capability (
            id, capability_id, object_id, object_type,
            priority, reason, sa_created_by, sa_owner_id
        ) VALUES (
            v_oc_id,
            v_capability_ids[i],
            v_t1_ids[i],
            'claimius.organization',
            CASE i WHEN 1 THEN 10 WHEN 2 THEN 5 WHEN 3 THEN 1 ELSE 0 END,
            CASE i
                WHEN 1 THEN 'High priority debug binding'
                WHEN 2 THEN 'Medium priority debug binding'
                WHEN 3 THEN 'Low priority debug binding'
                ELSE NULL
            END,
            v_user_claim_id,
            v_t1_ids[i]
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_oc_id,
            p_object_type   => 'public.object_capability',
            p_sa_owner_id   => v_t1_ids[i],
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding object_capability ' || i
        );
    END LOOP;

    RAISE NOTICE 'Inserted 10 capability rows and 4 object_capability ties for debug user.';
END $$;
