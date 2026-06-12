CREATE OR REPLACE FUNCTION claimius.normalize_object_type(p_object_type TEXT)
RETURNS TEXT AS $$
    SELECT CASE
        WHEN p_object_type IS NULL THEN NULL
        WHEN position('.' IN p_object_type) = 0 THEN p_object_type
        ELSE split_part(p_object_type, '.', 2)
    END;
$$ LANGUAGE sql IMMUTABLE;

GRANT EXECUTE ON FUNCTION claimius.normalize_object_type(TEXT) TO claimius_reader, claimius_writer, claimius_admin;

CREATE OR REPLACE FUNCTION claimius.merge_graphs(p_a JSONB, p_b JSONB)
RETURNS JSONB AS $$
DECLARE
    v_a_objects JSONB := COALESCE(p_a -> 'objects', '{}'::jsonb);
    v_b_objects JSONB := COALESCE(p_b -> 'objects', '{}'::jsonb);
    v_objects   JSONB := v_a_objects;
    v_links     JSONB;
    v_type      TEXT;
BEGIN
    FOR v_type IN SELECT jsonb_object_keys(v_b_objects) LOOP
        v_objects := jsonb_set(
            v_objects,
            ARRAY[v_type],
            COALESCE(v_objects -> v_type, '{}'::jsonb) || (v_b_objects -> v_type)
        );
    END LOOP;

    WITH all_links AS (
        SELECT l FROM jsonb_array_elements(COALESCE(p_a -> 'link', '[]'::jsonb)) AS l
        UNION
        SELECT l FROM jsonb_array_elements(COALESCE(p_b -> 'link', '[]'::jsonb)) AS l
    )
    SELECT COALESCE(jsonb_agg(l), '[]'::jsonb) INTO v_links FROM all_links;

    RETURN jsonb_build_object('objects', v_objects, 'link', v_links);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

GRANT EXECUTE ON FUNCTION claimius.merge_graphs(JSONB, JSONB) TO claimius_reader, claimius_writer, claimius_admin;

CREATE OR REPLACE FUNCTION claimius.graph_type_passes(
    p_object_type     TEXT,
    p_include_types   TEXT[],
    p_exclude_types   TEXT[]
) RETURNS BOOLEAN AS $$
DECLARE
    v_norm TEXT := claimius.normalize_object_type(p_object_type);
BEGIN
    IF p_include_types IS NOT NULL AND array_length(p_include_types, 1) IS NOT NULL THEN
        IF NOT (p_object_type = ANY(p_include_types) OR v_norm = ANY(p_include_types)) THEN
            RETURN FALSE;
        END IF;
    END IF;
    IF p_exclude_types IS NOT NULL AND array_length(p_exclude_types, 1) IS NOT NULL THEN
        IF p_object_type = ANY(p_exclude_types) OR v_norm = ANY(p_exclude_types) THEN
            RETURN FALSE;
        END IF;
    END IF;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

GRANT EXECUTE ON FUNCTION claimius.graph_type_passes(TEXT, TEXT[], TEXT[]) TO claimius_reader, claimius_writer, claimius_admin;

CREATE OR REPLACE FUNCTION claimius.get_graph_objects(
    p_user_id         UUID,
    p_app_id          UUID,
    p_required_access INTEGER DEFAULT 4,
    p_include_types   TEXT[] DEFAULT NULL,
    p_exclude_types   TEXT[] DEFAULT NULL,
    p_object_ids      UUID[] DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN '{}'::jsonb;
    END IF;

    WITH visible AS (
        SELECT uo.object_id,
               claimius.normalize_object_type(uo.object_type) AS norm_type,
               jsonb_build_object(
                   'label',       coalesce(uo.sa_name, uo.object_id::TEXT),
                   'description', uo.sa_description,
                   'access',      uo.sa_access,
                   'scope',       uo.scope,
                   'owner_id',    uo.sa_owner_id,
                   'location_id', uo.sa_location_id,
                   'link',        uo.sa_link
               ) AS data
        FROM claimius.user_object uo
        WHERE uo.user_id = p_user_id
          AND uo.app_id = p_app_id
          AND (p_required_access = 0 OR (uo.sa_access & p_required_access) = p_required_access)
          AND (p_object_ids IS NULL OR uo.object_id = ANY(p_object_ids))
          AND claimius.graph_type_passes(uo.object_type, p_include_types, p_exclude_types)
    ),
    grouped AS (
        SELECT norm_type,
               jsonb_object_agg(object_id::TEXT, data) AS objects
        FROM visible
        GROUP BY norm_type
    )
    SELECT COALESCE(jsonb_object_agg(norm_type, objects), '{}'::jsonb) INTO v_result FROM grouped;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

GRANT EXECUTE ON FUNCTION claimius.get_graph_objects(UUID, UUID, INTEGER, TEXT[], TEXT[], UUID[]) TO claimius_reader, claimius_writer, claimius_admin;

CREATE OR REPLACE FUNCTION claimius.get_graph_links_owner(
    p_user_id         UUID,
    p_app_id          UUID,
    p_required_access INTEGER DEFAULT 4,
    p_include_types   TEXT[] DEFAULT NULL,
    p_exclude_types   TEXT[] DEFAULT NULL,
    p_start_id        UUID DEFAULT NULL,
    p_depth           INTEGER DEFAULT 0
) RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
BEGIN
    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN '[]'::jsonb;
    END IF;

    WITH visible AS (
        SELECT uo.object_id, uo.object_type
        FROM claimius.user_object uo
        WHERE uo.user_id = p_user_id
          AND uo.app_id = p_app_id
          AND (p_required_access = 0 OR (uo.sa_access & p_required_access) = p_required_access)
          AND claimius.graph_type_passes(uo.object_type, p_include_types, p_exclude_types)
    ),
    in_scope AS (
        SELECT v.object_id, v.object_type
        FROM visible v
        WHERE p_start_id IS NULL
           OR v.object_id = p_start_id
           OR EXISTS (
               SELECT 1 FROM claimius.inheritance_info ii
               WHERE ii.ancestor_id = p_start_id
                 AND ii.descendant_id = v.object_id
                 AND ii.descendant_type = v.object_type
                 AND ii.depth >= 1
                 AND (p_depth = 0 OR ii.depth <= p_depth)
           )
    ),
    edges AS (
        SELECT DISTINCT
               ii.ancestor_type AS source_type,
               ii.ancestor_id AS source_id,
               ii.descendant_type AS target_type,
               ii.descendant_id AS target_id,
               ii.tree_type::TEXT AS relation_raw
        FROM claimius.inheritance_info ii
        JOIN in_scope vs ON vs.object_id = ii.ancestor_id   AND vs.object_type = ii.ancestor_type
        JOIN in_scope vt ON vt.object_id = ii.descendant_id AND vt.object_type = ii.descendant_type
        WHERE ii.depth = 1
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'source_type', claimius.normalize_object_type(source_type),
        'source_id',   source_id,
        'target_type', claimius.normalize_object_type(target_type),
        'target_id',   target_id,
        'relation',    CASE relation_raw WHEN 'ownership' THEN 'owner' ELSE relation_raw END
    )), '[]'::jsonb) INTO v_result FROM edges;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

GRANT EXECUTE ON FUNCTION claimius.get_graph_links_owner(UUID, UUID, INTEGER, TEXT[], TEXT[], UUID, INTEGER) TO claimius_reader, claimius_writer, claimius_admin;

CREATE OR REPLACE FUNCTION claimius.get_graph_links_claim(
    p_user_id         UUID,
    p_app_id          UUID,
    p_required_access INTEGER DEFAULT 0,
    p_include_types   TEXT[] DEFAULT NULL,
    p_exclude_types   TEXT[] DEFAULT NULL,
    p_start_id        UUID DEFAULT NULL,
    p_depth           INTEGER DEFAULT 0
) RETURNS JSONB AS $$
DECLARE
    v_user_row_id UUID;
    v_claim_ids   UUID[];
    v_objects     JSONB := '{}'::jsonb;
    v_links       JSONB := '[]'::jsonb;
    v_part        JSONB;
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN jsonb_build_object('objects', '{}'::jsonb, 'link', '[]'::jsonb);
    END IF;

    SELECT u.id INTO v_user_row_id
    FROM claimius.samna_user u
    WHERE u.user_id = p_user_id AND u.app_id = p_app_id AND u.sa_deleted_at IS NULL
    LIMIT 1;

    IF p_start_id IS NULL THEN
        SELECT array_agg(uc.claim_id) INTO v_claim_ids
        FROM claimius.user_claim uc
        JOIN claimius.claim c ON c.id = uc.claim_id
        WHERE uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.sa_deleted_at IS NULL
          AND c.sa_deleted_at IS NULL
          AND (p_required_access = 0 OR (c.sa_access & p_required_access) = p_required_access);
    ELSE
        SELECT array_agg(uc.claim_id) INTO v_claim_ids
        FROM claimius.user_claim uc
        JOIN claimius.claim c ON c.id = uc.claim_id
        WHERE uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.claim_id = p_start_id
          AND uc.sa_deleted_at IS NULL
          AND c.sa_deleted_at IS NULL
          AND (p_required_access = 0 OR (c.sa_access & p_required_access) = p_required_access);
    END IF;

    IF v_claim_ids IS NULL THEN
        v_claim_ids := ARRAY[]::UUID[];
    END IF;

    IF v_user_row_id IS NOT NULL AND claimius.graph_type_passes('claimius.samna_user', p_include_types, p_exclude_types) THEN
        SELECT jsonb_build_object(
            'samna_user',
            jsonb_object_agg(
                u.id::TEXT,
                jsonb_build_object(
                    'label',       coalesce(nullif(trim(coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'')), ''), u.email, u.user_id::TEXT),
                    'access',      NULL::INTEGER,
                    'scope',       NULL::JSONB,
                    'user_id',     u.user_id,
                    'email',       u.email,
                    'external_id', u.external_id,
                    'status',      u.status,
                    'self',        TRUE
                )
            )
        ) INTO v_part
        FROM claimius.samna_user u
        WHERE u.id = v_user_row_id;
        v_objects := v_objects || COALESCE(v_part, '{}'::jsonb);
    END IF;

    IF claimius.graph_type_passes('claimius.samna_user', p_include_types, p_exclude_types) THEN
        SELECT jsonb_build_object(
            'samna_user',
            COALESCE(jsonb_object_agg(
                u.id::TEXT,
                jsonb_build_object(
                    'label',       coalesce(nullif(trim(coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'')), ''), u.email, u.user_id::TEXT),
                    'access',      uo.sa_access,
                    'scope',       uo.scope,
                    'user_id',     u.user_id,
                    'email',       u.email,
                    'external_id', u.external_id,
                    'status',      u.status,
                    'self',        FALSE
                )
            ), '{}'::jsonb)
        ) INTO v_part
        FROM claimius.samna_user u
        JOIN claimius.user_users uu ON uu.viewer_id = p_user_id AND uu.app_id = p_app_id AND uu.target_user_id = u.user_id
        LEFT JOIN claimius.user_object uo
               ON uo.object_id = u.id AND uo.object_type = 'claimius.samna_user'
              AND uo.user_id = p_user_id AND uo.app_id = p_app_id
        WHERE u.app_id = p_app_id
          AND u.sa_deleted_at IS NULL
          AND u.id <> COALESCE(v_user_row_id, '00000000-0000-0000-0000-000000000000'::UUID);
        v_objects := claimius.merge_graphs(
            jsonb_build_object('objects', v_objects, 'link', '[]'::jsonb),
            jsonb_build_object('objects', COALESCE(v_part, '{}'::jsonb), 'link', '[]'::jsonb)
        ) -> 'objects';
    END IF;

    IF claimius.graph_type_passes('claimius.claim', p_include_types, p_exclude_types) THEN
        SELECT jsonb_build_object(
            'claim',
            COALESCE(jsonb_object_agg(
                c.id::TEXT,
                jsonb_build_object(
                    'label',       c.name,
                    'description', c.description,
                    'access',      c.sa_access,
                    'inherits',    c.inherits,
                    'type',        c.type
                )
            ), '{}'::jsonb)
        ) INTO v_part
        FROM claimius.claim c
        WHERE c.app_id = p_app_id
          AND c.sa_deleted_at IS NULL
          AND c.id = ANY(v_claim_ids);
        v_objects := v_objects || COALESCE(v_part, '{}'::jsonb);
    END IF;

    IF claimius.graph_type_passes('claimius.user_claim', p_include_types, p_exclude_types) THEN
        SELECT jsonb_build_object(
            'user_claim',
            COALESCE(jsonb_object_agg(
                uc.id::TEXT,
                jsonb_build_object(
                    'label',     c.name,
                    'access',    NULL::INTEGER,
                    'scope',     NULL::JSONB,
                    'claim_id',  uc.claim_id,
                    'starts_at', uc.starts_at,
                    'ends_at',   uc.ends_at,
                    'reason',    uc.reason
                )
            ), '{}'::jsonb)
        ) INTO v_part
        FROM claimius.user_claim uc
        JOIN claimius.claim c ON c.id = uc.claim_id
        WHERE uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.sa_deleted_at IS NULL
          AND uc.claim_id = ANY(v_claim_ids);
        v_objects := v_objects || COALESCE(v_part, '{}'::jsonb);
    END IF;

    IF claimius.graph_type_passes('claimius.claim_object', p_include_types, p_exclude_types) THEN
        SELECT jsonb_build_object(
            'claim_object',
            COALESCE(jsonb_object_agg(
                co.id::TEXT,
                jsonb_build_object(
                    'label',       coalesce(uo.sa_name, co.object_id::TEXT, ''),
                    'access',      co.sa_access,
                    'scope',       co.scope,
                    'inherits',    co.inherits,
                    'target_id',   co.object_id,
                    'target_type', claimius.normalize_object_type(co.object_type)
                )
            ), '{}'::jsonb)
        ) INTO v_part
        FROM claimius.claim_object co
        LEFT JOIN claimius.user_object uo
               ON uo.object_id = co.object_id AND uo.object_type = co.object_type
              AND uo.user_id = p_user_id AND uo.app_id = p_app_id
        WHERE co.app_id = p_app_id
          AND co.sa_deleted_at IS NULL
          AND co.claim_id = ANY(v_claim_ids);
        v_objects := v_objects || COALESCE(v_part, '{}'::jsonb);
    END IF;

    v_objects := claimius.merge_graphs(
        jsonb_build_object('objects', v_objects, 'link', '[]'::jsonb),
        jsonb_build_object(
            'objects', claimius.get_graph_objects(p_user_id, p_app_id, p_required_access, p_include_types, p_exclude_types, NULL::UUID[]),
            'link', '[]'::jsonb
        )
    ) -> 'objects';

    WITH spine AS (
        SELECT jsonb_build_object(
            'source_type', 'samna_user',
            'source_id',   v_user_row_id,
            'target_type', 'user_claim',
            'target_id',   uc.id,
            'relation',    'holds'
        ) AS link
        FROM claimius.user_claim uc
        WHERE v_user_row_id IS NOT NULL
          AND uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.sa_deleted_at IS NULL
          AND uc.claim_id = ANY(v_claim_ids)
        UNION ALL
        SELECT jsonb_build_object(
            'source_type', 'user_claim',
            'source_id',   uc.id,
            'target_type', 'claim',
            'target_id',   uc.claim_id,
            'relation',    'grants'
        )
        FROM claimius.user_claim uc
        WHERE uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.sa_deleted_at IS NULL
          AND uc.claim_id = ANY(v_claim_ids)
        UNION ALL
        SELECT jsonb_build_object(
            'source_type', 'claim',
            'source_id',   co.claim_id,
            'target_type', 'claim_object',
            'target_id',   co.id,
            'relation',    'binds'
        )
        FROM claimius.claim_object co
        WHERE co.app_id = p_app_id
          AND co.sa_deleted_at IS NULL
          AND co.claim_id = ANY(v_claim_ids)
        UNION ALL
        SELECT jsonb_build_object(
            'source_type', 'claim_object',
            'source_id',   co.id,
            'target_type', claimius.normalize_object_type(co.object_type),
            'target_id',   co.object_id,
            'relation',    'direct'
        )
        FROM claimius.claim_object co
        JOIN claimius.user_object uo
               ON uo.object_id = co.object_id AND uo.object_type = co.object_type
              AND uo.user_id = p_user_id AND uo.app_id = p_app_id
        WHERE co.app_id = p_app_id
          AND co.sa_deleted_at IS NULL
          AND co.claim_id = ANY(v_claim_ids)
          AND co.object_id IS NOT NULL
          AND claimius.graph_type_passes(co.object_type, p_include_types, p_exclude_types)
        UNION ALL
        SELECT jsonb_build_object(
            'source_type', 'claim_object',
            'source_id',   co.id,
            'target_type', claimius.normalize_object_type(ii.descendant_type),
            'target_id',   ii.descendant_id,
            'relation',    CASE ii.tree_type::TEXT WHEN 'ownership' THEN 'owner' ELSE ii.tree_type::TEXT END
        )
        FROM claimius.claim_object co
        JOIN claimius.inheritance_info ii
               ON ii.ancestor_type = co.object_type
              AND ii.ancestor_id   = co.object_id
              AND ii.depth >= 1
              AND (p_depth = 0 OR ii.depth <= p_depth)
        JOIN claimius.user_object uo
               ON uo.object_id = ii.descendant_id AND uo.object_type = ii.descendant_type
              AND uo.user_id = p_user_id AND uo.app_id = p_app_id
        WHERE co.app_id = p_app_id
          AND co.sa_deleted_at IS NULL
          AND co.inherits = TRUE
          AND co.claim_id = ANY(v_claim_ids)
          AND claimius.graph_type_passes(ii.descendant_type, p_include_types, p_exclude_types)
        UNION ALL
        SELECT jsonb_build_object(
            'source_type', 'samna_user',
            'source_id',   v_user_row_id,
            'target_type', 'samna_user',
            'target_id',   u.id,
            'relation',    'visibility'
        )
        FROM claimius.samna_user u
        JOIN claimius.user_users uu ON uu.viewer_id = p_user_id AND uu.app_id = p_app_id AND uu.target_user_id = u.user_id
        WHERE v_user_row_id IS NOT NULL
          AND u.app_id = p_app_id
          AND u.sa_deleted_at IS NULL
          AND u.id <> v_user_row_id
    )
    SELECT COALESCE(jsonb_agg(link), '[]'::jsonb) INTO v_links FROM spine;

    RETURN jsonb_build_object('objects', v_objects, 'link', v_links);
END;
$$ LANGUAGE plpgsql STABLE;

GRANT EXECUTE ON FUNCTION claimius.get_graph_links_claim(UUID, UUID, INTEGER, TEXT[], TEXT[], UUID, INTEGER) TO claimius_reader, claimius_writer, claimius_admin;
