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
        SELECT 'booking', bk.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object('name', bk.name)
                    ELSE jsonb_build_object(
                        'name',        bk.name,
                        'description', bk.description,
                        'schedule',    bk.schedule,
                        'status',      bk.status,
                        'reserved_at', bk.reserved_at,
                        'canceled_at', bk.canceled_at
                    )
               END
        FROM public.booking bk
        JOIN visible v ON v.object_id = bk.id AND v.object_type = 'public.booking'
        WHERE bk.sa_deleted_at IS NULL

        UNION ALL
        SELECT 'checkin', c.id,
               CASE WHEN p_compact
                    THEN jsonb_build_object(
                        'name',
                        CASE
                            WHEN c.check_out IS NOT NULL THEN 'Check-out: ' || coalesce(bk.name, c.starts_at::TEXT)
                            WHEN c.check_in IS NOT NULL  THEN 'Check-in: '  || coalesce(bk.name, c.starts_at::TEXT)
                            ELSE 'Pending: ' || coalesce(bk.name, c.starts_at::TEXT)
                        END
                    )
                    ELSE jsonb_build_object(
                        'name',
                        CASE
                            WHEN c.check_out IS NOT NULL THEN 'Check-out: ' || coalesce(bk.name, c.starts_at::TEXT)
                            WHEN c.check_in IS NOT NULL  THEN 'Check-in: '  || coalesce(bk.name, c.starts_at::TEXT)
                            ELSE 'Pending: ' || coalesce(bk.name, c.starts_at::TEXT)
                        END,
                        'starts_at', c.starts_at,
                        'ends_at',   c.ends_at,
                        'check_in',  c.check_in,
                        'check_out', c.check_out,
                        'type',      c.type
                    )
               END
        FROM public.checkin c
        LEFT JOIN public.booking bk ON bk.checkin_id = c.id AND bk.sa_deleted_at IS NULL
        JOIN visible v ON v.object_id = c.id AND v.object_type = 'public.checkin'
        WHERE c.sa_deleted_at IS NULL

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
