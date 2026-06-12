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
    v_links JSONB;
BEGIN
    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN jsonb_build_object('links', '[]'::jsonb);
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
        SELECT DISTINCT ON (ii.tree_type, ii.descendant_type, ii.descendant_id)
               ii.ancestor_type AS source_type,
               ii.ancestor_id AS source_id,
               ii.descendant_type AS target_type,
               ii.descendant_id AS target_id,
               ii.tree_type::TEXT AS relation_raw
        FROM claimius.inheritance_info ii
        JOIN in_scope vs ON vs.object_id = ii.ancestor_id   AND vs.object_type = ii.ancestor_type
        JOIN in_scope vt ON vt.object_id = ii.descendant_id AND vt.object_type = ii.descendant_type
        WHERE ii.depth >= 1
        ORDER BY ii.tree_type, ii.descendant_type, ii.descendant_id, ii.depth ASC
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'source_type', claimius.normalize_object_type(source_type),
        'source_id',   source_id,
        'target_type', claimius.normalize_object_type(target_type),
        'target_id',   target_id,
        'relation',    CASE relation_raw WHEN 'ownership' THEN 'owner' ELSE relation_raw END
    )), '[]'::jsonb) INTO v_links FROM edges;

    RETURN jsonb_build_object('links', v_links);
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
    v_links       JSONB;
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN jsonb_build_object('links', '[]'::jsonb);
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

    WITH cascade_edges AS (
        SELECT DISTINCT ON (co.id, ii.descendant_type, ii.descendant_id, ii.tree_type)
               co.id AS co_id,
               co.claim_id AS claim_id,
               co.reason AS reason,
               ii.descendant_type AS target_type,
               ii.descendant_id AS target_id,
               ii.tree_type::TEXT AS tree_type,
               ii.depth AS depth
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
        ORDER BY co.id, ii.descendant_type, ii.descendant_id, ii.tree_type, ii.depth ASC
    ),
    spine AS (
        SELECT jsonb_build_object(
            'source_type',  'samna_user',
            'source_id',    v_user_row_id,
            'target_type',  'claim',
            'target_id',    uc.claim_id,
            'relation',     'holds',
            'relation_id',  uc.id,
            'relation_type','user_claim',
            'reason',       uc.reason,
            'starts_at',    uc.starts_at,
            'ends_at',      uc.ends_at
        ) AS link
        FROM claimius.user_claim uc
        WHERE v_user_row_id IS NOT NULL
          AND uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.sa_deleted_at IS NULL
          AND uc.claim_id = ANY(v_claim_ids)

        UNION ALL
        SELECT jsonb_build_object(
            'source_type',  'claim',
            'source_id',    co.claim_id,
            'target_type',  claimius.normalize_object_type(co.object_type),
            'target_id',    co.object_id,
            'relation',     'direct',
            'relation_id',  co.id,
            'relation_type','claim_object',
            'reason',       co.reason
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
            'source_type',  'claim',
            'source_id',    ce.claim_id,
            'target_type',  claimius.normalize_object_type(ce.target_type),
            'target_id',    ce.target_id,
            'relation',     CASE ce.tree_type WHEN 'ownership' THEN 'owner' ELSE ce.tree_type END,
            'relation_id',  ce.co_id,
            'relation_type','claim_object',
            'reason',       ce.reason
        )
        FROM cascade_edges ce

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

        UNION ALL
        SELECT jsonb_build_object(
            'source_type',  'samna_user',
            'source_id',    su.id,
            'target_type',  claimius.normalize_object_type(ur.object_type),
            'target_id',    ur.object_id,
            'relation',     'user_relation',
            'relation_id',  ur.id,
            'relation_type','user_relation',
            'reason',       ur.description,
            'pinned',       ur.pinned,
            'priority',     ur.priority,
            'used_at',      ur.used_at
        )
        FROM claimius.user_relation ur
        JOIN claimius.samna_user su ON su.user_id = ur.user_id AND su.app_id = p_app_id AND su.sa_deleted_at IS NULL
        JOIN claimius.user_object uo
               ON uo.object_id = ur.object_id AND uo.object_type = ur.object_type
              AND uo.user_id = p_user_id AND uo.app_id = p_app_id
        WHERE ur.app_id = p_app_id
          AND ur.sa_deleted_at IS NULL
          AND ur.user_id = p_user_id
          AND claimius.graph_type_passes(ur.object_type, p_include_types, p_exclude_types)
    )
    SELECT COALESCE(jsonb_agg(link), '[]'::jsonb) INTO v_links FROM spine;

    RETURN jsonb_build_object('links', v_links);
END;
$$ LANGUAGE plpgsql STABLE;

GRANT EXECUTE ON FUNCTION claimius.get_graph_links_claim(UUID, UUID, INTEGER, TEXT[], TEXT[], UUID, INTEGER) TO claimius_reader, claimius_writer, claimius_admin;
