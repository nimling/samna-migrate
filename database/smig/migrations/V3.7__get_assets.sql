DROP FUNCTION IF EXISTS public.get_assets(TEXT, UUID, TEXT, BOOLEAN, BOOLEAN);

CREATE OR REPLACE FUNCTION public.get_assets(
    p_object_type          TEXT,
    p_object_id            UUID,
    p_mime_type            TEXT DEFAULT NULL,
    p_include_parent_types BOOLEAN DEFAULT FALSE,
    p_propagate            BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    asset_id        UUID,
    object_asset_id UUID,
    mime_type       TEXT,
    index           INTEGER,
    level           INTEGER,
    hop             INTEGER,
    object_type     TEXT,
    object_id       UUID
) AS $$
DECLARE
    v_anchor_type    TEXT := p_object_type;
    v_anchor_id      UUID := p_object_id;
    v_bookable_id    UUID := NULL;
    v_type_id        UUID := NULL;
    v_target_type_id UUID := NULL;
    v_mime_pattern   TEXT := NULL;
BEGIN
    IF p_mime_type IS NOT NULL AND p_mime_type <> '' THEN
        v_mime_pattern := replace(p_mime_type, '*', '%');
    END IF;

    IF p_object_type = 'public.booking' THEN
        SELECT bk.bookable_id INTO v_bookable_id
        FROM public.booking bk
        WHERE bk.id = p_object_id AND bk.sa_deleted_at IS NULL;

        IF v_bookable_id IS NOT NULL THEN
            v_anchor_type := 'public.bookable';
            v_anchor_id   := v_bookable_id;
        END IF;
    END IF;

    IF v_anchor_type = 'public.bookable' THEN
        SELECT b.type_id INTO v_type_id
        FROM public.bookable b
        WHERE b.id = v_anchor_id AND b.sa_deleted_at IS NULL;
    END IF;

    IF v_anchor_type = 'public.bookable_type' THEN
        v_target_type_id := v_anchor_id;
    END IF;

    RETURN QUERY
    WITH
    parenthood_chain AS (
        SELECT a.object_id AS anc_id, a.object_type AS anc_type, a.hop
        FROM claimius.get_ancestors(v_anchor_type, v_anchor_id) a
        WHERE p_propagate
          AND a.tree_type   = 'parenthood'
          AND a.object_type = v_anchor_type
          AND NOT (a.object_id = v_anchor_id AND a.object_type = v_anchor_type)
    ),
    location_chain AS (
        SELECT a.object_id AS anc_id, a.object_type AS anc_type, a.hop
        FROM claimius.get_ancestors(v_anchor_type, v_anchor_id) a
        WHERE p_propagate
          AND a.tree_type   = 'location'
          AND a.object_type = 'claimius.location'
          AND NOT (a.object_id = v_anchor_id AND a.object_type = v_anchor_type)
    ),
    owner_chain AS (
        SELECT a.object_id AS anc_id, a.object_type AS anc_type, a.hop
        FROM claimius.get_ancestors(v_anchor_type, v_anchor_id) a
        WHERE p_propagate
          AND a.tree_type   = 'ownership'
          AND a.object_type = 'claimius.organization'
          AND NOT (a.object_id = v_anchor_id AND a.object_type = v_anchor_type)
    ),
    parent_type_chain AS (
        SELECT b.type_id AS anc_id, 'public.bookable_type'::TEXT AS anc_type, pc.hop
        FROM parenthood_chain pc
        JOIN public.bookable b ON b.id = pc.anc_id AND b.sa_deleted_at IS NULL
        WHERE p_propagate
          AND p_include_parent_types
          AND v_anchor_type = 'public.bookable'
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
    direct_oa AS (
        SELECT oa.asset_id,
               oa.id            AS object_asset_id,
               a.mime_type      AS mime_type,
               COALESCE(oa.index, 0) AS index,
               0                AS level,
               0                AS hop,
               p_object_type    AS object_type,
               p_object_id      AS object_id
        FROM public.object_asset oa
        JOIN public.asset a ON a.id = oa.asset_id AND a.sa_deleted_at IS NULL
        WHERE oa.object_type = p_object_type
          AND oa.object_id   = p_object_id
          AND oa.sa_deleted_at IS NULL
          AND (v_mime_pattern IS NULL OR a.mime_type LIKE v_mime_pattern)
    ),
    bookable_oa AS (
        SELECT oa.asset_id,
               oa.id,
               a.mime_type,
               COALESCE(oa.index, 0),
               1                AS level,
               0                AS hop,
               'public.bookable'::TEXT,
               v_bookable_id
        FROM public.object_asset oa
        JOIN public.asset a ON a.id = oa.asset_id AND a.sa_deleted_at IS NULL
        WHERE p_object_type = 'public.booking'
          AND v_bookable_id IS NOT NULL
          AND oa.object_type = 'public.bookable'
          AND oa.object_id   = v_bookable_id
          AND oa.sa_deleted_at IS NULL
          AND (v_mime_pattern IS NULL OR a.mime_type LIKE v_mime_pattern)
    ),
    type_oa AS (
        SELECT oa.asset_id,
               oa.id,
               a.mime_type,
               COALESCE(oa.index, 0),
               2                AS level,
               0                AS hop,
               'public.bookable_type'::TEXT,
               v_type_id
        FROM public.object_asset oa
        JOIN public.asset a ON a.id = oa.asset_id AND a.sa_deleted_at IS NULL
        WHERE p_propagate
          AND v_type_id IS NOT NULL
          AND oa.object_type = 'public.bookable_type'
          AND oa.object_id   = v_type_id
          AND oa.sa_deleted_at IS NULL
          AND (v_mime_pattern IS NULL OR a.mime_type LIKE v_mime_pattern)
    ),
    own_type_oa AS (
        SELECT oa.asset_id,
               oa.id,
               a.mime_type,
               COALESCE(oa.index, 0),
               2                AS level,
               otc.hop          AS hop,
               otc.anc_type,
               otc.anc_id
        FROM own_type_chain otc
        JOIN public.object_asset oa
             ON oa.object_id   = otc.anc_id
            AND oa.object_type = 'public.bookable_type'
            AND oa.sa_deleted_at IS NULL
        JOIN public.asset a ON a.id = oa.asset_id AND a.sa_deleted_at IS NULL
        WHERE (v_mime_pattern IS NULL OR a.mime_type LIKE v_mime_pattern)
    ),
    parenthood_oa AS (
        SELECT oa.asset_id,
               oa.id,
               a.mime_type,
               COALESCE(oa.index, 0),
               3                AS level,
               pc.hop           AS hop,
               pc.anc_type,
               pc.anc_id
        FROM parenthood_chain pc
        JOIN public.object_asset oa
             ON oa.object_id   = pc.anc_id
            AND oa.object_type = pc.anc_type
            AND oa.sa_deleted_at IS NULL
        JOIN public.asset a ON a.id = oa.asset_id AND a.sa_deleted_at IS NULL
        WHERE (v_mime_pattern IS NULL OR a.mime_type LIKE v_mime_pattern)
    ),
    parent_type_oa AS (
        SELECT oa.asset_id,
               oa.id,
               a.mime_type,
               COALESCE(oa.index, 0),
               4                AS level,
               ptc.hop          AS hop,
               ptc.anc_type,
               ptc.anc_id
        FROM parent_type_chain ptc
        JOIN public.object_asset oa
             ON oa.object_id   = ptc.anc_id
            AND oa.object_type = 'public.bookable_type'
            AND oa.sa_deleted_at IS NULL
        JOIN public.asset a ON a.id = oa.asset_id AND a.sa_deleted_at IS NULL
        WHERE (v_mime_pattern IS NULL OR a.mime_type LIKE v_mime_pattern)
    ),
    parent_type_parent_oa AS (
        SELECT oa.asset_id,
               oa.id,
               a.mime_type,
               COALESCE(oa.index, 0),
               4                AS level,
               ptpc.hop         AS hop,
               ptpc.anc_type,
               ptpc.anc_id
        FROM parent_type_parent_chain ptpc
        JOIN public.object_asset oa
             ON oa.object_id   = ptpc.anc_id
            AND oa.object_type = 'public.bookable_type'
            AND oa.sa_deleted_at IS NULL
        JOIN public.asset a ON a.id = oa.asset_id AND a.sa_deleted_at IS NULL
        WHERE (v_mime_pattern IS NULL OR a.mime_type LIKE v_mime_pattern)
    ),
    location_oa AS (
        SELECT oa.asset_id,
               oa.id,
               a.mime_type,
               COALESCE(oa.index, 0),
               5                AS level,
               lc.hop           AS hop,
               lc.anc_type,
               lc.anc_id
        FROM location_chain lc
        JOIN public.object_asset oa
             ON oa.object_id   = lc.anc_id
            AND oa.object_type = lc.anc_type
            AND oa.sa_deleted_at IS NULL
        JOIN public.asset a ON a.id = oa.asset_id AND a.sa_deleted_at IS NULL
        WHERE (v_mime_pattern IS NULL OR a.mime_type LIKE v_mime_pattern)
    ),
    owner_oa AS (
        SELECT oa.asset_id,
               oa.id,
               a.mime_type,
               COALESCE(oa.index, 0),
               6                AS level,
               oc.hop           AS hop,
               oc.anc_type,
               oc.anc_id
        FROM owner_chain oc
        JOIN public.object_asset oa
             ON oa.object_id   = oc.anc_id
            AND oa.object_type = oc.anc_type
            AND oa.sa_deleted_at IS NULL
        JOIN public.asset a ON a.id = oa.asset_id AND a.sa_deleted_at IS NULL
        WHERE (v_mime_pattern IS NULL OR a.mime_type LIKE v_mime_pattern)
    ),
    merged AS (
        SELECT * FROM direct_oa
        UNION ALL
        SELECT * FROM bookable_oa
        UNION ALL
        SELECT * FROM type_oa
        UNION ALL
        SELECT * FROM own_type_oa
        UNION ALL
        SELECT * FROM parenthood_oa
        UNION ALL
        SELECT * FROM parent_type_oa
        UNION ALL
        SELECT * FROM parent_type_parent_oa
        UNION ALL
        SELECT * FROM location_oa
        UNION ALL
        SELECT * FROM owner_oa
    )
    SELECT DISTINCT ON (m.asset_id)
        m.asset_id, m.object_asset_id, m.mime_type, m.index, m.level, m.hop, m.object_type, m.object_id
    FROM merged m
    ORDER BY m.asset_id, m.level ASC, m.hop ASC, m.index ASC;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION public.get_assets(TEXT, UUID, TEXT, BOOLEAN, BOOLEAN) IS 'Cascade assets for an object. Direct bindings on the starting object return at level 0. When the start is a booking, the booking is level 0 and its bookable is level 1. The bookable type is level 2, parenthood ancestors are level 3, ancestor bookable types are level 4 when p_include_parent_types is set, location ancestors are level 5, owner ancestors are level 6. When p_propagate is FALSE only direct bindings (and the bookable for a booking start) are returned. p_mime_type accepts a glob using * which maps to SQL LIKE; NULL or empty returns every mime type. One row per asset, lowest level then hop then index wins.';
