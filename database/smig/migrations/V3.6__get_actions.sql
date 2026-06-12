DROP FUNCTION IF EXISTS public.get_actions(TEXT, UUID, TEXT, BOOLEAN, BOOLEAN);

CREATE OR REPLACE FUNCTION public.get_actions(
    p_object_type          TEXT,
    p_object_id            UUID,
    p_trigger              TEXT,
    p_include_parent_types BOOLEAN DEFAULT FALSE,
    p_propagate            BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    action_object_id UUID,
    action_id        UUID,
    level            INTEGER,
    hop              INTEGER,
    priority         INTEGER,
    dedup_mode       TEXT
) AS $$
DECLARE
    v_type_id        UUID := NULL;
    v_target_type_id UUID := NULL;
BEGIN
    IF p_object_type = 'public.bookable' THEN
        SELECT b.type_id INTO v_type_id
        FROM public.bookable b
        WHERE b.id = p_object_id AND b.sa_deleted_at IS NULL;
    END IF;

    IF p_object_type = 'public.bookable_type' THEN
        v_target_type_id := p_object_id;
    END IF;

    RETURN QUERY
    WITH
    parenthood_chain AS (
        SELECT a.object_id AS anc_id, a.object_type AS anc_type, a.hop
        FROM claimius.get_ancestors(p_object_type, p_object_id) a
        WHERE p_propagate
          AND a.tree_type   = 'parenthood'
          AND a.object_type = p_object_type
          AND NOT (a.object_id = p_object_id AND a.object_type = p_object_type)
    ),
    location_chain AS (
        SELECT a.object_id AS anc_id, a.object_type AS anc_type, a.hop
        FROM claimius.get_ancestors(p_object_type, p_object_id) a
        WHERE p_propagate
          AND a.tree_type   = 'location'
          AND a.object_type = 'claimius.location'
          AND NOT (a.object_id = p_object_id AND a.object_type = p_object_type)
    ),
    owner_chain AS (
        SELECT a.object_id AS anc_id, a.object_type AS anc_type, a.hop
        FROM claimius.get_ancestors(p_object_type, p_object_id) a
        WHERE p_propagate
          AND a.tree_type   = 'ownership'
          AND a.object_type = 'claimius.organization'
          AND NOT (a.object_id = p_object_id AND a.object_type = p_object_type)
    ),
    parent_type_chain AS (
        SELECT b.type_id AS anc_id, 'public.bookable_type'::TEXT AS anc_type, pc.hop
        FROM parenthood_chain pc
        JOIN public.bookable b ON b.id = pc.anc_id AND b.sa_deleted_at IS NULL
        WHERE p_propagate
          AND p_include_parent_types
          AND p_object_type = 'public.bookable'
          AND pc.anc_type   = 'public.bookable'
          AND b.type_id IS NOT NULL
    ),
    own_type_chain AS (
        SELECT a.object_id AS anc_id, 'public.bookable_type'::TEXT AS anc_type, a.hop
        FROM claimius.get_parenthood_ancestors('public.bookable_type', COALESCE(v_type_id, v_target_type_id)) a
        WHERE p_propagate
          AND COALESCE(v_type_id, v_target_type_id) IS NOT NULL
          AND NOT (a.object_id = COALESCE(v_type_id, v_target_type_id) AND a.object_type = 'public.bookable_type')
    ),
    parent_type_parent_chain AS (
        SELECT a.object_id AS anc_id, 'public.bookable_type'::TEXT AS anc_type, ptc.hop + a.hop AS hop
        FROM parent_type_chain ptc
        CROSS JOIN LATERAL claimius.get_parenthood_ancestors('public.bookable_type', ptc.anc_id) a
        WHERE p_propagate
          AND p_include_parent_types
          AND NOT (a.object_id = ptc.anc_id AND a.object_type = 'public.bookable_type')
    ),
    direct_ao AS (
        SELECT ao.id        AS action_object_id,
               a.id         AS action_id,
               0            AS level,
               0            AS hop,
               ao.priority  AS priority,
               a.dedup_mode AS dedup_mode
        FROM public.action_object ao
        JOIN public.action a ON a.id = ao.action_id AND a.sa_deleted_at IS NULL
        WHERE ao.object_type = p_object_type
          AND ao.object_id   = p_object_id
          AND ao.sa_deleted_at IS NULL
          AND a.trigger = p_trigger
    ),
    type_ao AS (
        SELECT ao.id, a.id, 1, 0, ao.priority, a.dedup_mode
        FROM public.action_object ao
        JOIN public.action a ON a.id = ao.action_id AND a.sa_deleted_at IS NULL
        WHERE p_propagate
          AND v_type_id IS NOT NULL
          AND ao.object_type = 'public.bookable_type'
          AND ao.object_id   = v_type_id
          AND ao.sa_deleted_at IS NULL
          AND a.trigger = p_trigger
    ),
    own_type_ao AS (
        SELECT ao.id, a.id, 1, otc.hop, ao.priority, a.dedup_mode
        FROM own_type_chain otc
        JOIN public.action_object ao
             ON ao.object_id   = otc.anc_id
            AND ao.object_type = 'public.bookable_type'
            AND ao.sa_deleted_at IS NULL
        JOIN public.action a ON a.id = ao.action_id AND a.sa_deleted_at IS NULL
        WHERE a.trigger = p_trigger
    ),
    parenthood_ao AS (
        SELECT ao.id, a.id, 2, pc.hop, ao.priority, a.dedup_mode
        FROM parenthood_chain pc
        JOIN public.action_object ao
             ON ao.object_id   = pc.anc_id
            AND ao.object_type = pc.anc_type
            AND ao.sa_deleted_at IS NULL
        JOIN public.action a ON a.id = ao.action_id AND a.sa_deleted_at IS NULL
        WHERE a.trigger = p_trigger
    ),
    parent_type_ao AS (
        SELECT ao.id, a.id, 3, ptc.hop, ao.priority, a.dedup_mode
        FROM parent_type_chain ptc
        JOIN public.action_object ao
             ON ao.object_id   = ptc.anc_id
            AND ao.object_type = 'public.bookable_type'
            AND ao.sa_deleted_at IS NULL
        JOIN public.action a ON a.id = ao.action_id AND a.sa_deleted_at IS NULL
        WHERE a.trigger = p_trigger
    ),
    parent_type_parent_ao AS (
        SELECT ao.id, a.id, 3, ptpc.hop, ao.priority, a.dedup_mode
        FROM parent_type_parent_chain ptpc
        JOIN public.action_object ao
             ON ao.object_id   = ptpc.anc_id
            AND ao.object_type = 'public.bookable_type'
            AND ao.sa_deleted_at IS NULL
        JOIN public.action a ON a.id = ao.action_id AND a.sa_deleted_at IS NULL
        WHERE a.trigger = p_trigger
    ),
    location_ao AS (
        SELECT ao.id, a.id, 4, lc.hop, ao.priority, a.dedup_mode
        FROM location_chain lc
        JOIN public.action_object ao
             ON ao.object_id   = lc.anc_id
            AND ao.object_type = lc.anc_type
            AND ao.sa_deleted_at IS NULL
        JOIN public.action a ON a.id = ao.action_id AND a.sa_deleted_at IS NULL
        WHERE a.trigger = p_trigger
    ),
    owner_ao AS (
        SELECT ao.id, a.id, 5, oc.hop, ao.priority, a.dedup_mode
        FROM owner_chain oc
        JOIN public.action_object ao
             ON ao.object_id   = oc.anc_id
            AND ao.object_type = oc.anc_type
            AND ao.sa_deleted_at IS NULL
        JOIN public.action a ON a.id = ao.action_id AND a.sa_deleted_at IS NULL
        WHERE a.trigger = p_trigger
    ),
    merged AS (
        SELECT * FROM direct_ao
        UNION ALL
        SELECT * FROM type_ao
        UNION ALL
        SELECT * FROM own_type_ao
        UNION ALL
        SELECT * FROM parenthood_ao
        UNION ALL
        SELECT * FROM parent_type_ao
        UNION ALL
        SELECT * FROM parent_type_parent_ao
        UNION ALL
        SELECT * FROM location_ao
        UNION ALL
        SELECT * FROM owner_ao
    )
    SELECT m.action_object_id, m.action_id, m.level, m.hop, m.priority, m.dedup_mode
    FROM merged m
    ORDER BY m.level ASC, m.hop ASC, m.priority ASC;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION public.get_actions(TEXT, UUID, TEXT, BOOLEAN, BOOLEAN) IS 'Cascade actions for an object trigger. Direct bindings always returned. When p_propagate is true, the function also walks parenthood, location, ownership, and bookable type chains. Set p_include_parent_types to also walk ancestor bookable type chains. One row per binding. Ordered level ASC (innermost first), hop ASC, priority ASC. Caller applies dedup_mode.';
