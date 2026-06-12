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
        SELECT ot.object_type        AS source_type,
               ot.object_id          AS source_id,
               'public.timeslot'::TEXT AS target_type,
               ot.timeslot_id        AS target_id,
               'timeslot'::TEXT      AS relation,
               ot.id                 AS relation_id,
               'object_timeslot'::TEXT AS relation_type,
               ot.reason             AS reason,
               ot.priority           AS priority,
               NULL::JSONB           AS input,
               ot.conditions         AS conditions
        FROM public.object_timeslot ot
        JOIN in_scope vh ON vh.object_id = ot.object_id   AND vh.object_type = ot.object_type
        JOIN in_scope vt ON vt.object_id = ot.timeslot_id AND vt.object_type = 'public.timeslot'
        WHERE ot.sa_deleted_at IS NULL

        UNION ALL
        SELECT oa.object_type, oa.object_id,
               'public.asset', oa.asset_id, 'asset',
               oa.id, 'object_asset',
               NULL::TEXT, oa.index, NULL::JSONB, NULL::JSONB
        FROM public.object_asset oa
        JOIN in_scope vh ON vh.object_id = oa.object_id AND vh.object_type = oa.object_type
        JOIN in_scope vt ON vt.object_id = oa.asset_id  AND vt.object_type = 'public.asset'
        WHERE oa.sa_deleted_at IS NULL

        UNION ALL
        SELECT oc.object_type, oc.object_id,
               'public.capability', oc.capability_id, 'capability',
               oc.id, 'object_capability',
               oc.reason, oc.priority, NULL::JSONB, NULL::JSONB
        FROM public.object_capability oc
        JOIN in_scope vh ON vh.object_id = oc.object_id      AND vh.object_type = oc.object_type
        JOIN in_scope vt ON vt.object_id = oc.capability_id  AND vt.object_type = 'public.capability'
        WHERE oc.sa_deleted_at IS NULL

        UNION ALL
        SELECT ao.object_type, ao.object_id,
               'public.action', ao.action_id, 'action',
               ao.id, 'action_object',
               ao.reason, ao.priority, ao.input, NULL::JSONB
        FROM public.action_object ao
        JOIN in_scope vh ON vh.object_id = ao.object_id  AND vh.object_type = ao.object_type
        JOIN in_scope vt ON vt.object_id = ao.action_id  AND vt.object_type = 'public.action'
        WHERE ao.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'public.bookable'::TEXT, b.id,
               'public.bookable_type'::TEXT, b.type_id,
               'type'::TEXT,
               NULL::UUID, NULL::TEXT,
               NULL::TEXT, NULL::INTEGER, NULL::JSONB, NULL::JSONB
        FROM public.bookable b
        JOIN in_scope vh ON vh.object_id = b.id      AND vh.object_type = 'public.bookable'
        JOIN in_scope vt ON vt.object_id = b.type_id AND vt.object_type = 'public.bookable_type'
        WHERE b.sa_deleted_at IS NULL
          AND b.type_id IS NOT NULL
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

    v := claimius.merge_graphs(v, jsonb_build_object(
        'objects', '{}'::jsonb,
        'links',   COALESCE(claimius.get_graph_links_owner(p_user_id, p_app_id, p_required_access, p_include_types, p_exclude_types, p_start_id, p_depth) -> 'links', '[]'::jsonb)
    ));

    IF 'claim' = ANY(p_with) THEN
        v := claimius.merge_graphs(v, public.get_claim_graph(p_user_id, p_app_id, NULL::UUID, p_depth, p_required_access, p_include_types, p_exclude_types, '{}'::TEXT[], p_with_image, p_compact));
    END IF;

    RETURN v;
END;
$$ LANGUAGE plpgsql STABLE;

GRANT EXECUTE ON FUNCTION public.get_relation_graph(UUID, UUID, UUID, INTEGER, INTEGER, TEXT[], TEXT[], TEXT[], BOOLEAN, BOOLEAN) TO claimius_reader, claimius_writer, claimius_admin;
