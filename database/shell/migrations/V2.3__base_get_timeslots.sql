DROP FUNCTION IF EXISTS public.get_timeslots(TEXT, UUID, BOOLEAN);
DROP FUNCTION IF EXISTS public.get_timeslots(TEXT, UUID, BOOLEAN, BOOLEAN);

CREATE OR REPLACE FUNCTION public.get_timeslots(
    p_object_type          TEXT,
    p_object_id            UUID,
    p_include_parent_types BOOLEAN DEFAULT FALSE,
    p_propagate            BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    timeslot_id  UUID,
    priority     INTEGER,
    reason       TEXT,
    conditions   JSONB,
    object_type  TEXT,
    object_id    UUID
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
    direct_ts AS (
        SELECT ot.timeslot_id,
               COALESCE(ot.priority, 0) AS priority,
               ot.reason,
               ot.conditions,
               p_object_type::TEXT AS object_type,
               p_object_id         AS object_id,
               0                   AS tier,
               0                   AS hop
        FROM public.object_timeslot ot
        JOIN public.timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
        WHERE ot.object_id   = p_object_id
          AND ot.object_type = p_object_type
          AND ot.sa_deleted_at IS NULL
    ),
    type_ts AS (
        SELECT ot.timeslot_id,
               COALESCE(ot.priority, 0) AS priority,
               ot.reason,
               ot.conditions,
               'public.bookable_type'::TEXT AS object_type,
               v_type_id                    AS object_id,
               1                            AS tier,
               0                            AS hop
        FROM public.object_timeslot ot
        JOIN public.timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
        WHERE p_propagate
          AND v_type_id IS NOT NULL
          AND ot.object_id   = v_type_id
          AND ot.object_type = 'public.bookable_type'
          AND ot.sa_deleted_at IS NULL
    ),
    own_type_ts AS (
        SELECT ot.timeslot_id,
               COALESCE(ot.priority, 0) AS priority,
               ot.reason,
               ot.conditions,
               otc.anc_type AS object_type,
               otc.anc_id   AS object_id,
               1            AS tier,
               otc.hop      AS hop
        FROM own_type_chain otc
        JOIN public.object_timeslot ot
             ON ot.object_id   = otc.anc_id
            AND ot.object_type = 'public.bookable_type'
            AND ot.sa_deleted_at IS NULL
        JOIN public.timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
    ),
    parenthood_ts AS (
        SELECT ot.timeslot_id,
               COALESCE(ot.priority, 0) AS priority,
               ot.reason,
               ot.conditions,
               pc.anc_type AS object_type,
               pc.anc_id   AS object_id,
               2           AS tier,
               pc.hop      AS hop
        FROM parenthood_chain pc
        JOIN public.object_timeslot ot
             ON ot.object_id   = pc.anc_id
            AND ot.object_type = pc.anc_type
            AND ot.sa_deleted_at IS NULL
        JOIN public.timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
    ),
    parent_type_ts AS (
        SELECT ot.timeslot_id,
               COALESCE(ot.priority, 0) AS priority,
               ot.reason,
               ot.conditions,
               ptc.anc_type AS object_type,
               ptc.anc_id   AS object_id,
               3            AS tier,
               ptc.hop      AS hop
        FROM parent_type_chain ptc
        JOIN public.object_timeslot ot
             ON ot.object_id   = ptc.anc_id
            AND ot.object_type = 'public.bookable_type'
            AND ot.sa_deleted_at IS NULL
        JOIN public.timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
    ),
    parent_type_parent_ts AS (
        SELECT ot.timeslot_id,
               COALESCE(ot.priority, 0) AS priority,
               ot.reason,
               ot.conditions,
               ptpc.anc_type AS object_type,
               ptpc.anc_id   AS object_id,
               3             AS tier,
               ptpc.hop      AS hop
        FROM parent_type_parent_chain ptpc
        JOIN public.object_timeslot ot
             ON ot.object_id   = ptpc.anc_id
            AND ot.object_type = 'public.bookable_type'
            AND ot.sa_deleted_at IS NULL
        JOIN public.timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
    ),
    location_ts AS (
        SELECT ot.timeslot_id,
               COALESCE(ot.priority, 0) AS priority,
               ot.reason,
               ot.conditions,
               lc.anc_type AS object_type,
               lc.anc_id   AS object_id,
               4           AS tier,
               lc.hop      AS hop
        FROM location_chain lc
        JOIN public.object_timeslot ot
             ON ot.object_id   = lc.anc_id
            AND ot.object_type = lc.anc_type
            AND ot.sa_deleted_at IS NULL
        JOIN public.timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
    ),
    owner_ts AS (
        SELECT ot.timeslot_id,
               COALESCE(ot.priority, 0) AS priority,
               ot.reason,
               ot.conditions,
               oc.anc_type AS object_type,
               oc.anc_id   AS object_id,
               5           AS tier,
               oc.hop      AS hop
        FROM owner_chain oc
        JOIN public.object_timeslot ot
             ON ot.object_id   = oc.anc_id
            AND ot.object_type = oc.anc_type
            AND ot.sa_deleted_at IS NULL
        JOIN public.timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
    ),
    merged AS (
        SELECT * FROM direct_ts
        UNION ALL
        SELECT * FROM type_ts
        UNION ALL
        SELECT * FROM own_type_ts
        UNION ALL
        SELECT * FROM parenthood_ts
        UNION ALL
        SELECT * FROM parent_type_ts
        UNION ALL
        SELECT * FROM parent_type_parent_ts
        UNION ALL
        SELECT * FROM location_ts
        UNION ALL
        SELECT * FROM owner_ts
    )
    SELECT DISTINCT ON (m.timeslot_id)
        m.timeslot_id, m.priority, m.reason, m.conditions, m.object_type, m.object_id
    FROM merged m
    ORDER BY m.timeslot_id, m.priority ASC, m.tier ASC, m.hop ASC;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION public.get_timeslots(TEXT, UUID, BOOLEAN, BOOLEAN) IS 'Cascade timeslots for an object. Direct bindings always returned. When p_propagate is true, the function also walks the parenthood, location, and ownership chains plus the bookable type chain. Set p_include_parent_types to also walk ancestor bookable type_id chains and their parent type chains. One row per timeslot, lowest priority binding wins.';
