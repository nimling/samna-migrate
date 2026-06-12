CREATE OR REPLACE FUNCTION claimius.graph_object_types()
    RETURNS TEXT[] AS $$
    SELECT ARRAY[
        'claimius.organization',
        'claimius.location',
        'claimius.samna_user',
        'claimius.samna_secret',
        'claimius.claim',
        'public.bookable',
        'public.bookable_type',
        'public.timeslot',
        'public.asset',
        'public.code',
        'public.capability',
        'public.action'
    ]::TEXT[];
$$ LANGUAGE sql IMMUTABLE;

GRANT EXECUTE ON FUNCTION claimius.graph_object_types() TO claimius_reader, claimius_writer, claimius_admin;


CREATE OR REPLACE FUNCTION claimius.get_graph_objects(
    p_user_id         UUID,
    p_app_id          UUID,
    p_required_access INTEGER DEFAULT 4,
    p_include_types   TEXT[] DEFAULT NULL,
    p_exclude_types   TEXT[] DEFAULT NULL,
    p_object_ids      UUID[] DEFAULT NULL,
    p_with_image      BOOLEAN DEFAULT FALSE,
    p_compact         BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
    v_allowed TEXT[] := claimius.graph_object_types();
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN '{}'::jsonb;
    END IF;

    WITH visible AS (
        SELECT uo.object_id, uo.object_type
        FROM claimius.user_object uo
        WHERE uo.user_id = p_user_id
          AND uo.app_id = p_app_id
          AND (p_required_access = 0 OR (uo.sa_access & p_required_access) = p_required_access)
          AND (p_object_ids IS NULL OR uo.object_id = ANY(p_object_ids))
          AND uo.object_type = ANY(v_allowed)
          AND claimius.graph_type_passes(uo.object_type, p_include_types, p_exclude_types)
    ),
    user_ids AS (
        SELECT u.id
        FROM claimius.samna_user u
        WHERE u.app_id = p_app_id
          AND u.sa_deleted_at IS NULL
          AND claimius.graph_type_passes('claimius.samna_user', p_include_types, p_exclude_types)
          AND (
              EXISTS (SELECT 1 FROM visible v WHERE v.object_id = u.id AND v.object_type = 'claimius.samna_user')
              OR u.user_id = p_user_id
              OR EXISTS (
                  SELECT 1 FROM claimius.user_users uu
                  WHERE uu.viewer_id = p_user_id
                    AND uu.app_id = p_app_id
                    AND uu.target_user_id = u.user_id
              )
          )
    ),
    claim_ids AS (
        SELECT c.id
        FROM claimius.claim c
        WHERE c.app_id = p_app_id
          AND c.sa_deleted_at IS NULL
          AND claimius.graph_type_passes('claimius.claim', p_include_types, p_exclude_types)
          AND (
              EXISTS (SELECT 1 FROM visible v WHERE v.object_id = c.id AND v.object_type = 'claimius.claim')
              OR EXISTS (
                  SELECT 1 FROM claimius.user_claim uc
                  WHERE uc.user_id = p_user_id
                    AND uc.app_id = p_app_id
                    AND uc.claim_id = c.id
                    AND uc.sa_deleted_at IS NULL
              )
          )
    ),
    image_for AS (
        SELECT v.object_id, v.object_type,
               jsonb_build_object('id', a.id, 'url', a.blob_url, 'mime_type', a.mime_type) AS image
        FROM visible v
        JOIN LATERAL (
            SELECT a.id, a.blob_url, a.mime_type
            FROM public.get_assets(v.object_type, v.object_id, 'image/*') ga
            JOIN public.asset a ON a.id = ga.asset_id AND a.sa_deleted_at IS NULL
            ORDER BY ga.level, ga.hop, ga.index
            LIMIT 1
        ) a ON TRUE
        WHERE p_with_image
    ),
    rows AS (
        SELECT 'organization'::TEXT AS norm_type, o.id AS object_id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', o.name)
                    ELSE jsonb_build_object(
                        'name',        o.name,
                        'description', o.description,
                        'type',        o.type,
                        'level',       o.sa_level,
                        'external_id', o.external_id
                    )
               END AS base
        FROM claimius.organization o
        JOIN visible v ON v.object_id = o.id AND v.object_type = 'claimius.organization'
        WHERE o.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'location', l.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', l.name)
                    ELSE jsonb_build_object(
                        'name',        l.name,
                        'description', l.description,
                        'type',        l.type,
                        'level',       l.sa_level,
                        'longitude',   l.longitude,
                        'latitude',    l.latitude,
                        'external_id', l.external_id,
                        'code_type',   l.code_type,
                        'code',        l.code
                    )
               END
        FROM claimius.location l
        JOIN visible v ON v.object_id = l.id AND v.object_type = 'claimius.location'
        WHERE l.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'samna_user', u.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', coalesce(nullif(trim(coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'')), ''), u.email, u.user_id::TEXT))
                    ELSE jsonb_build_object(
                        'name',        coalesce(nullif(trim(coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'')), ''), u.email, u.user_id::TEXT),
                        'first_name',  u.first_name,
                        'last_name',   u.last_name,
                        'user_name',   u.user_name,
                        'user_image',  u.user_image,
                        'phone',       u.phone,
                        'email',       u.email,
                        'external_id', u.external_id,
                        'status',      u.status,
                        'type',        u.type,
                        'config',      u.config,
                        'user_id',     u.user_id,
                        'self',        (u.user_id = p_user_id)
                    )
               END
        FROM claimius.samna_user u
        JOIN user_ids ui ON ui.id = u.id
        WHERE u.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'samna_secret', s.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', s.key)
                    ELSE jsonb_build_object('name', s.key, 'expires_at', s.expires_at)
               END
        FROM claimius.samna_secret s
        JOIN visible v ON v.object_id = s.id AND v.object_type = 'claimius.samna_secret'
        WHERE s.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'claim', c.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', c.name)
                    ELSE jsonb_build_object(
                        'name',        c.name,
                        'description', c.description,
                        'access',      c.sa_access,
                        'inherits',    c.inherits,
                        'type',        c.type,
                        'is_deny',     (c.sa_access & 16) <> 0
                    )
               END
        FROM claimius.claim c
        JOIN claim_ids ci ON ci.id = c.id
        WHERE c.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'bookable', b.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', b.name)
                    ELSE jsonb_build_object('name', b.name, 'description', b.description)
               END
        FROM public.bookable b
        JOIN visible v ON v.object_id = b.id AND v.object_type = 'public.bookable'
        WHERE b.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'bookable_type', bt.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', bt.name)
                    ELSE jsonb_build_object('name', bt.name, 'description', bt.description, 'keywords', to_jsonb(bt.keywords))
               END
        FROM public.bookable_type bt
        JOIN visible v ON v.object_id = bt.id AND v.object_type = 'public.bookable_type'
        WHERE bt.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'timeslot', t.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', t.name)
                    ELSE jsonb_build_object('name', t.name, 'description', t.description, 'schedule', t.schedule)
               END
        FROM public.timeslot t
        JOIN visible v ON v.object_id = t.id AND v.object_type = 'public.timeslot'
        WHERE t.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'asset', a.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', a.name)
                    ELSE jsonb_build_object(
                        'name',        a.name,
                        'description', a.description,
                        'mime_type',   a.mime_type,
                        'status',      a.status,
                        'blob_url',    a.blob_url
                    )
               END
        FROM public.asset a
        JOIN visible v ON v.object_id = a.id AND v.object_type = 'public.asset'
        WHERE a.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'code', c.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', c.name)
                    ELSE jsonb_build_object(
                        'name',        c.name,
                        'description', c.description,
                        'value',       c.value,
                        'data',        c.data,
                        'styling',     c.styling,
                        'expires_at',  c.expires_at
                    )
               END
        FROM public.code c
        JOIN visible v ON v.object_id = c.id AND v.object_type = 'public.code'
        WHERE c.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'capability', cp.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', cp.name)
                    ELSE jsonb_build_object(
                        'name',        cp.name,
                        'description', cp.description,
                        'locale',      cp.locale,
                        'value',       cp.value,
                        'render',      cp.render
                    )
               END
        FROM public.capability cp
        JOIN visible v ON v.object_id = cp.id AND v.object_type = 'public.capability'
        WHERE cp.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'action', ac.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', ac.name)
                    ELSE jsonb_build_object(
                        'name',             ac.name,
                        'description',      ac.description,
                        'trigger',          ac.trigger,
                        'code',             ac.code,
                        'public',           ac.public,
                        'continue_on_fail', ac.continue_on_fail,
                        'dedup_mode',       ac.dedup_mode,
                        'input',            ac.input
                    )
               END
        FROM public.action ac
        JOIN visible v ON v.object_id = ac.id AND v.object_type = 'public.action'
        WHERE ac.sa_deleted_at IS NULL
    ),
    enriched AS (
        SELECT r.norm_type, r.object_id,
               r.base || COALESCE(jsonb_build_object('image', img.image), '{}'::jsonb) AS data
        FROM rows r
        LEFT JOIN image_for img ON img.object_id = r.object_id
        WHERE r.norm_type IS NOT NULL
    ),
    grouped AS (
        SELECT norm_type, jsonb_object_agg(object_id::TEXT, data) AS objects
        FROM enriched
        GROUP BY norm_type
    )
    SELECT COALESCE(jsonb_object_agg(norm_type, objects), '{}'::jsonb) INTO v_result FROM grouped;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

GRANT EXECUTE ON FUNCTION claimius.get_graph_objects(UUID, UUID, INTEGER, TEXT[], TEXT[], UUID[], BOOLEAN, BOOLEAN) TO claimius_reader, claimius_writer, claimius_admin;


DROP FUNCTION IF EXISTS claimius.get_graph_links_owner(UUID, UUID, INTEGER, TEXT[], TEXT[], UUID, INTEGER);

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
    v_links   JSONB;
    v_allowed TEXT[] := claimius.graph_object_types();
BEGIN
    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN jsonb_build_object('links', '[]'::jsonb);
    END IF;

    WITH ancestor_pool AS (
        SELECT uo.object_id, uo.object_type
        FROM claimius.user_object uo
        WHERE uo.user_id = p_user_id
          AND uo.app_id = p_app_id
          AND (p_required_access = 0 OR (uo.sa_access & p_required_access) = p_required_access)
          AND uo.object_type = ANY(v_allowed)
    ),
    descendants AS (
        SELECT uo.object_id, uo.object_type
        FROM claimius.user_object uo
        WHERE uo.user_id = p_user_id
          AND uo.app_id = p_app_id
          AND (p_required_access = 0 OR (uo.sa_access & p_required_access) = p_required_access)
          AND uo.object_type = ANY(v_allowed)
          AND claimius.graph_type_passes(uo.object_type, p_include_types, p_exclude_types)

        UNION
        SELECT c.id AS object_id, 'claimius.claim'::TEXT AS object_type
        FROM claimius.claim c
        WHERE c.app_id = p_app_id
          AND c.sa_deleted_at IS NULL
          AND claimius.graph_type_passes('claimius.claim', p_include_types, p_exclude_types)
          AND EXISTS (
              SELECT 1 FROM claimius.user_claim uc
              WHERE uc.user_id = p_user_id
                AND uc.app_id = p_app_id
                AND uc.claim_id = c.id
                AND uc.sa_deleted_at IS NULL
          )
    ),
    in_scope AS (
        SELECT d.object_id, d.object_type
        FROM descendants d
        WHERE p_start_id IS NULL
           OR d.object_id = p_start_id
           OR EXISTS (
               SELECT 1 FROM claimius.inheritance_info ii
               WHERE ii.ancestor_id = p_start_id
                 AND ii.descendant_id = d.object_id
                 AND ii.descendant_type = d.object_type
                 AND ii.depth >= 1
                 AND (p_depth = 0 OR ii.depth <= p_depth)
           )
    ),
    inheritance_edges AS (
        SELECT DISTINCT ON (ii.tree_type, ii.descendant_type, ii.descendant_id)
               ii.ancestor_type   AS source_type,
               ii.ancestor_id     AS source_id,
               ii.descendant_type AS target_type,
               ii.descendant_id   AS target_id,
               ii.tree_type::TEXT AS relation_raw
        FROM claimius.inheritance_info ii
        JOIN ancestor_pool ap ON ap.object_id = ii.ancestor_id   AND ap.object_type = ii.ancestor_type
        JOIN in_scope      vt ON vt.object_id = ii.descendant_id AND vt.object_type = ii.descendant_type
        WHERE ii.depth >= 1
        ORDER BY ii.tree_type, ii.descendant_type, ii.descendant_id, ii.depth ASC
    ),
    edges AS (
        SELECT source_type, source_id, target_type, target_id, relation_raw
        FROM inheritance_edges
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
    v        JSONB;
    v_links  JSONB;
    v_allowed TEXT[] := claimius.graph_object_types();
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
          AND uo.object_type = ANY(v_allowed)
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
    ),
    filtered AS (
        SELECT * FROM edges e
        WHERE e.source_type = ANY(v_allowed)
          AND e.target_type = ANY(v_allowed)
          AND claimius.graph_type_passes(e.source_type, p_include_types, p_exclude_types)
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
