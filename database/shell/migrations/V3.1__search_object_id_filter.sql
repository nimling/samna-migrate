DROP FUNCTION IF EXISTS claimius.search(UUID, UUID, TEXT, TEXT[], INTEGER, INTEGER, INTEGER);

CREATE OR REPLACE FUNCTION claimius.search(
    p_user_id            UUID,
    p_app_id             UUID,
    p_query              TEXT,
    p_object_types       TEXT[] DEFAULT NULL,
    p_required_access    INTEGER DEFAULT 0,
    p_object_ids         UUID[] DEFAULT NULL,
    p_exclude_object_ids UUID[] DEFAULT NULL,
    p_limit              INTEGER DEFAULT 20,
    p_offset             INTEGER DEFAULT 0
) RETURNS TABLE(
                   object_id           UUID,
                   object_type         TEXT,
                   user_claim_id       UUID,
                   name                TEXT,
                   description         TEXT,
                   link                TEXT,
                   sa_access           INTEGER,
                   scope               JSONB,
                   owner_id            UUID,
                   location_id         UUID,
                   is_direct_grant     BOOLEAN,
                   rank                REAL
               ) AS $$
DECLARE
    v_tsquery TSQUERY;
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    v_tsquery := websearch_to_tsquery('simple', p_query);

    RETURN QUERY
        SELECT
            claimius.user_object.object_id,
            claimius.user_object.object_type,
            best.uc_id,
            claimius.user_object.sa_name,
            claimius.user_object.sa_description,
            claimius.user_object.sa_link,
            claimius.user_object.sa_access,
            claimius.user_object.scope,
            claimius.user_object.sa_owner_id,
            claimius.user_object.sa_location_id,
            (claimius.user_object.direct_grant AND best.uc_id IS NULL),
            ts_rank(claimius.user_object.search_vector, v_tsquery)
        FROM claimius.user_object
                 LEFT JOIN LATERAL (
            SELECT uc.id AS uc_id
            FROM jsonb_array_elements(claimius.user_object.grants) g
                     JOIN claimius.user_claim uc ON uc.claim_id = (g ->> 'claim_id')::UUID
                AND uc.user_id = p_user_id
                AND uc.app_id = p_app_id
                AND uc.sa_deleted_at IS NULL
                AND (uc.starts_at IS NULL OR uc.starts_at <= now())
                AND (uc.ends_at IS NULL OR uc.ends_at > now())
                     JOIN claimius.claim c ON c.id = uc.claim_id AND c.sa_deleted_at IS NULL
            WHERE ((g ->> 'access')::INTEGER & p_required_access) = p_required_access
            ORDER BY claimius._popcount((g ->> 'access')::INTEGER) DESC
            LIMIT 1
            ) best ON TRUE
        WHERE claimius.user_object.user_id = p_user_id
          AND claimius.user_object.app_id = p_app_id
          AND (claimius.user_object.sa_access & p_required_access) = p_required_access
          AND claimius.user_object.search_vector @@ v_tsquery
          AND (p_object_types IS NULL OR claimius.user_object.object_type = ANY(p_object_types))
          AND (p_object_ids IS NULL OR claimius.user_object.object_id = ANY(p_object_ids))
          AND (p_exclude_object_ids IS NULL OR NOT (claimius.user_object.object_id = ANY(p_exclude_object_ids)))
          AND (best.uc_id IS NOT NULL OR claimius.user_object.direct_grant)
        ORDER BY ts_rank(claimius.user_object.search_vector, v_tsquery) DESC
        LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.search(UUID, UUID, TEXT, TEXT[], INTEGER, UUID[], UUID[], INTEGER, INTEGER) IS 'Full text search over accessible objects whose mask covers p_required_access. user_claim_id is the actor token from the strongest surviving claim grant per object. p_object_ids and p_exclude_object_ids filter by object_id at the SQL layer.';


DROP FUNCTION IF EXISTS public.search(UUID, TEXT, TEXT[], INTEGER, INTEGER, INTEGER, UUID[], UUID[], UUID);

CREATE OR REPLACE FUNCTION public.search(
    p_user_id            UUID,
    p_query              TEXT    DEFAULT NULL,
    p_object_types       TEXT[]  DEFAULT NULL,
    p_required_access    INTEGER DEFAULT 0,
    p_limit              INTEGER DEFAULT 20,
    p_offset             INTEGER DEFAULT 0,
    p_owner_ids          UUID[]  DEFAULT NULL,
    p_location_ids       UUID[]  DEFAULT NULL,
    p_claim_id           UUID    DEFAULT NULL,
    p_object_ids         UUID[]  DEFAULT NULL,
    p_exclude_object_ids UUID[]  DEFAULT NULL
)
    RETURNS TABLE
            (
                object_id       UUID,
                object_type     TEXT,
                user_claim_id   UUID,
                name            TEXT,
                description     TEXT,
                link            TEXT,
                sa_access       INTEGER,
                scope           JSONB,
                owner_id        UUID,
                location_id     UUID,
                is_direct_grant BOOLEAN,
                rank            REAL
            )
AS
$$
DECLARE
    v_app_id        UUID    := claimius.get_disciple_app_id();
    v_has_query     BOOLEAN := (p_query IS NOT NULL AND length(btrim(p_query)) > 0);
    v_default_types TEXT[]  := ARRAY[
        'public.bookable',
        'public.booking',
        'public.timeslot',
        'public.bookable_type',
        'public.capability',
        'public.asset',
        'public.code'
    ];
    v_types         TEXT[]  := coalesce(p_object_types, v_default_types);
    v_tsq           TSQUERY := NULL;
BEGIN
    IF v_has_query THEN
        v_tsq := to_tsquery('simple',
            array_to_string(
                ARRAY(
                    SELECT lower(btrim(word)) || ':*'
                    FROM regexp_split_to_table(btrim(p_query), '\s+') word
                    WHERE length(btrim(word)) > 0
                ),
                ' & '
            )
        );
    END IF;

    RETURN QUERY
        WITH accessible AS (
            SELECT t          AS object_type,
                   go.object_id,
                   go.user_claim_id,
                   go.sa_name        AS name,
                   go.sa_description AS description,
                   go.sa_link        AS link,
                   go.sa_access,
                   go.scope,
                   go.sa_owner_id    AS owner_id,
                   go.sa_location_id AS location_id,
                   go.direct_grant   AS is_direct_grant
            FROM unnest(v_types) AS t
            CROSS JOIN LATERAL claimius.get_objects(p_user_id, v_app_id, t, p_required_access) go
        )
        SELECT DISTINCT ON (a.object_id, a.object_type)
            a.object_id,
            a.object_type,
            a.user_claim_id,
            a.name,
            a.description,
            a.link,
            a.sa_access,
            a.scope,
            a.owner_id,
            a.location_id,
            a.is_direct_grant,
            CASE WHEN v_tsq IS NULL THEN 0::REAL ELSE coalesce(ts_rank(si.search_vector, v_tsq), 0)::REAL END AS rank
        FROM accessible a
        LEFT JOIN public.search_index si
              ON si.object_id   = a.object_id
             AND si.object_type = a.object_type
        WHERE (v_tsq IS NULL OR (si.search_vector IS NOT NULL AND si.search_vector @@ v_tsq))
          AND (p_owner_ids    IS NULL OR a.owner_id    = ANY(p_owner_ids))
          AND (p_location_ids IS NULL OR a.location_id = ANY(p_location_ids))
          AND (p_object_ids   IS NULL OR a.object_id   = ANY(p_object_ids))
          AND (p_exclude_object_ids IS NULL OR NOT (a.object_id = ANY(p_exclude_object_ids)))
          AND (p_claim_id IS NULL OR EXISTS (
              SELECT 1
              FROM claimius.get_claims(p_user_id, v_app_id, a.object_id, a.object_type) gc
              WHERE gc.id = p_claim_id
          ))
        ORDER BY
            a.object_id,
            a.object_type,
            CASE WHEN v_tsq IS NULL THEN 0::REAL ELSE coalesce(ts_rank(si.search_vector, v_tsq), 0)::REAL END DESC
        LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE;
