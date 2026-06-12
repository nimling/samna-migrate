CREATE OR REPLACE FUNCTION claimius.merge_graphs(p_a JSONB, p_b JSONB)
RETURNS JSONB AS $$
DECLARE
    v_a      JSONB := COALESCE(p_a, '{}'::jsonb);
    v_b      JSONB := COALESCE(p_b, '{}'::jsonb);
    v_a_obj  JSONB := COALESCE(v_a -> 'objects', '{}'::jsonb);
    v_b_obj  JSONB := COALESCE(v_b -> 'objects', '{}'::jsonb);
    v_objs   JSONB := v_a_obj;
    v_links  JSONB;
    v_type   TEXT;
BEGIN
    FOR v_type IN SELECT jsonb_object_keys(v_b_obj) LOOP
        v_objs := jsonb_set(
            v_objs,
            ARRAY[v_type],
            COALESCE(v_objs -> v_type, '{}'::jsonb) || (v_b_obj -> v_type)
        );
    END LOOP;

    WITH all_links AS (
        SELECT l FROM jsonb_array_elements(COALESCE(v_a -> 'links', '[]'::jsonb)) AS l
        UNION
        SELECT l FROM jsonb_array_elements(COALESCE(v_b -> 'links', '[]'::jsonb)) AS l
    )
    SELECT COALESCE(jsonb_agg(l), '[]'::jsonb) INTO v_links FROM all_links;

    RETURN jsonb_build_object('objects', v_objs, 'links', v_links);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

GRANT EXECUTE ON FUNCTION claimius.merge_graphs(JSONB, JSONB) TO claimius_reader, claimius_writer, claimius_admin;


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

    WITH spine AS (
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
            'source_id',    co.claim_id,
            'target_type',  claimius.normalize_object_type(ii.descendant_type),
            'target_id',    ii.descendant_id,
            'relation',     CASE ii.tree_type::TEXT WHEN 'ownership' THEN 'owner' ELSE ii.tree_type::TEXT END,
            'relation_id',  co.id,
            'relation_type','claim_object',
            'reason',       co.reason
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


CREATE OR REPLACE FUNCTION public.get_owner_graph(
    p_user_id         UUID,
    p_app_id          UUID,
    p_start_id        UUID DEFAULT NULL,
    p_depth           INTEGER DEFAULT 0,
    p_required_access INTEGER DEFAULT 4,
    p_include_types   TEXT[] DEFAULT NULL,
    p_exclude_types   TEXT[] DEFAULT NULL,
    p_with            TEXT[] DEFAULT '{}'::TEXT[],
    p_with_image      BOOLEAN DEFAULT FALSE,
    p_compact         BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
DECLARE
    v JSONB;
BEGIN
    v := jsonb_build_object(
        'objects', claimius.get_graph_objects(p_user_id, p_app_id, p_required_access, p_include_types, p_exclude_types, NULL::UUID[], p_with_image, p_compact),
        'links',   COALESCE(claimius.get_graph_links_owner(p_user_id, p_app_id, p_required_access, p_include_types, p_exclude_types, p_start_id, p_depth) -> 'links', '[]'::jsonb)
    );

    IF 'claim' = ANY(p_with) THEN
        v := claimius.merge_graphs(v, public.get_claim_graph(p_user_id, p_app_id, NULL::UUID, p_depth, p_required_access, p_include_types, p_exclude_types, '{}'::TEXT[], p_with_image, p_compact));
    END IF;

    IF 'relation' = ANY(p_with) THEN
        v := claimius.merge_graphs(v, public.get_relation_graph(p_user_id, p_app_id, NULL::UUID, p_depth, p_required_access, p_include_types, p_exclude_types, '{}'::TEXT[], p_with_image, p_compact));
    END IF;

    RETURN v;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION public.get_claim_graph(
    p_user_id         UUID,
    p_app_id          UUID,
    p_start_id        UUID DEFAULT NULL,
    p_depth           INTEGER DEFAULT 0,
    p_required_access INTEGER DEFAULT 0,
    p_include_types   TEXT[] DEFAULT NULL,
    p_exclude_types   TEXT[] DEFAULT NULL,
    p_with            TEXT[] DEFAULT '{}'::TEXT[],
    p_with_image      BOOLEAN DEFAULT FALSE,
    p_compact         BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
DECLARE
    v JSONB;
BEGIN
    v := jsonb_build_object(
        'objects', claimius.get_graph_objects(p_user_id, p_app_id, p_required_access, p_include_types, p_exclude_types, NULL::UUID[], p_with_image, p_compact),
        'links',   COALESCE(claimius.get_graph_links_claim(p_user_id, p_app_id, p_required_access, p_include_types, p_exclude_types, p_start_id, p_depth) -> 'links', '[]'::jsonb)
    );

    IF 'owner' = ANY(p_with) THEN
        v := claimius.merge_graphs(v, jsonb_build_object(
            'objects', '{}'::jsonb,
            'links',   COALESCE(claimius.get_graph_links_owner(p_user_id, p_app_id, p_required_access, p_include_types, p_exclude_types, NULL::UUID, p_depth) -> 'links', '[]'::jsonb)
        ));
    END IF;

    IF 'relation' = ANY(p_with) THEN
        v := claimius.merge_graphs(v, public.get_relation_graph(p_user_id, p_app_id, NULL::UUID, p_depth, p_required_access, p_include_types, p_exclude_types, '{}'::TEXT[], p_with_image, p_compact));
    END IF;

    RETURN v;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION public.get_relation_graph(
    p_user_id         UUID,
    p_app_id          UUID,
    p_start_id        UUID DEFAULT NULL,
    p_depth           INTEGER DEFAULT 0,
    p_required_access INTEGER DEFAULT 4,
    p_include_types   TEXT[] DEFAULT NULL,
    p_exclude_types   TEXT[] DEFAULT NULL,
    p_with            TEXT[] DEFAULT '{}'::TEXT[],
    p_with_image      BOOLEAN DEFAULT FALSE,
    p_compact         BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
DECLARE
    v       JSONB;
    v_links JSONB;
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN jsonb_build_object('objects', '{}'::jsonb, 'links', '[]'::jsonb);
    END IF;

    WITH visible AS (
        SELECT uo.object_id, uo.object_type
        FROM claimius.user_object uo
        WHERE uo.user_id = p_user_id
          AND uo.app_id = p_app_id
          AND (p_required_access = 0 OR (uo.sa_access & p_required_access) = p_required_access)
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
        SELECT ot.object_type AS source_type, ot.object_id AS source_id,
               'public.timeslot'::TEXT AS target_type, ot.timeslot_id AS target_id,
               'timeslot'::TEXT AS relation,
               ot.id AS relation_id, 'object_timeslot'::TEXT AS relation_type,
               ot.reason, ot.priority, ot.conditions
        FROM public.object_timeslot ot
        JOIN in_scope vh ON vh.object_id = ot.object_id   AND vh.object_type = ot.object_type
        JOIN in_scope vt ON vt.object_id = ot.timeslot_id AND vt.object_type = 'public.timeslot'
        WHERE ot.sa_deleted_at IS NULL

        UNION ALL
        SELECT oa.object_type, oa.object_id,
               'public.asset', oa.asset_id, 'asset',
               oa.id, 'object_asset',
               NULL::TEXT, oa.index, NULL::JSONB
        FROM public.object_asset oa
        JOIN in_scope vh ON vh.object_id = oa.object_id AND vh.object_type = oa.object_type
        JOIN in_scope vt ON vt.object_id = oa.asset_id  AND vt.object_type = 'public.asset'
        WHERE oa.sa_deleted_at IS NULL

        UNION ALL
        SELECT oc.object_type, oc.object_id,
               'public.capability', oc.capability_id, 'capability',
               oc.id, 'object_capability',
               oc.reason, oc.priority, NULL::JSONB
        FROM public.object_capability oc
        JOIN in_scope vh ON vh.object_id = oc.object_id      AND vh.object_type = oc.object_type
        JOIN in_scope vt ON vt.object_id = oc.capability_id  AND vt.object_type = 'public.capability'
        WHERE oc.sa_deleted_at IS NULL

        UNION ALL
        SELECT ao.object_type, ao.object_id,
               'public.action', ao.action_id, 'action',
               ao.id, 'action_object',
               ao.reason, ao.priority, ao.input
        FROM public.action_object ao
        JOIN in_scope vh ON vh.object_id = ao.object_id  AND vh.object_type = ao.object_type
        JOIN in_scope vt ON vt.object_id = ao.action_id  AND vt.object_type = 'public.action'
        WHERE ao.sa_deleted_at IS NULL
    ),
    filtered AS (
        SELECT * FROM edges e
        WHERE claimius.graph_type_passes(e.source_type, p_include_types, p_exclude_types)
          AND claimius.graph_type_passes(e.target_type, p_include_types, p_exclude_types)
    )
    SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'source_type',  claimius.normalize_object_type(source_type),
        'source_id',    source_id,
        'target_type',  claimius.normalize_object_type(target_type),
        'target_id',    target_id,
        'relation',     relation,
        'relation_id',  relation_id,
        'relation_type',relation_type,
        'reason',       reason,
        'priority',     priority,
        'input',        input,
        'conditions',   conditions
    ))), '[]'::jsonb) INTO v_links FROM filtered;

    v := jsonb_build_object(
        'objects', claimius.get_graph_objects(p_user_id, p_app_id, p_required_access, p_include_types, p_exclude_types, NULL::UUID[], p_with_image, p_compact),
        'links',   v_links
    );

    IF 'owner' = ANY(p_with) THEN
        v := claimius.merge_graphs(v, jsonb_build_object(
            'objects', '{}'::jsonb,
            'links',   COALESCE(claimius.get_graph_links_owner(p_user_id, p_app_id, p_required_access, p_include_types, p_exclude_types, p_start_id, p_depth) -> 'links', '[]'::jsonb)
        ));
    END IF;

    IF 'claim' = ANY(p_with) THEN
        v := claimius.merge_graphs(v, public.get_claim_graph(p_user_id, p_app_id, NULL::UUID, p_depth, p_required_access, p_include_types, p_exclude_types, '{}'::TEXT[], p_with_image, p_compact));
    END IF;

    RETURN v;
END;
$$ LANGUAGE plpgsql STABLE;

GRANT EXECUTE ON FUNCTION public.get_owner_graph(UUID, UUID, UUID, INTEGER, INTEGER, TEXT[], TEXT[], TEXT[], BOOLEAN, BOOLEAN) TO claimius_reader, claimius_writer, claimius_admin;
GRANT EXECUTE ON FUNCTION public.get_claim_graph(UUID, UUID, UUID, INTEGER, INTEGER, TEXT[], TEXT[], TEXT[], BOOLEAN, BOOLEAN) TO claimius_reader, claimius_writer, claimius_admin;
GRANT EXECUTE ON FUNCTION public.get_relation_graph(UUID, UUID, UUID, INTEGER, INTEGER, TEXT[], TEXT[], TEXT[], BOOLEAN, BOOLEAN) TO claimius_reader, claimius_writer, claimius_admin;
