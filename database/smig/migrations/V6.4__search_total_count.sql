DROP FUNCTION IF EXISTS claimius.search(UUID, UUID, TEXT, TEXT[], INTEGER, UUID[], UUID[], INTEGER, INTEGER);

CREATE OR REPLACE FUNCTION claimius.search(
    p_user_id            UUID,
    p_app_id             UUID,
    p_query              TEXT,
    p_object_types       TEXT[] DEFAULT NULL,
    p_required_access    INTEGER DEFAULT 0,
    p_object_ids         UUID[] DEFAULT NULL,
    p_exclude_object_ids UUID[] DEFAULT NULL,
    p_owner_subtree_ids  UUID[] DEFAULT NULL,
    p_parent_id          UUID   DEFAULT NULL,
    p_parent_type        TEXT   DEFAULT NULL,
    p_type_ids           UUID[] DEFAULT NULL,
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
                   rank                REAL,
                   total_count         INTEGER
               ) AS $$
DECLARE
    v_tsquery        TSQUERY;
    v_include_claim  BOOLEAN := p_object_types IS NULL OR 'claimius.claim' = ANY(p_object_types);
    v_include_others BOOLEAN := p_object_types IS NULL OR EXISTS (
        SELECT 1 FROM unnest(p_object_types) t WHERE t <> 'claimius.claim'
    );
    v_has_scope      BOOLEAN := p_owner_subtree_ids IS NOT NULL
                              OR p_parent_id IS NOT NULL
                              OR p_type_ids IS NOT NULL;
    v_parent_tree    claimius.tree_type;
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    v_tsquery := websearch_to_tsquery('simple', p_query);

    IF p_parent_type IS NOT NULL THEN
        v_parent_tree := CASE p_parent_type
                            WHEN 'claimius.location' THEN 'location'::claimius.tree_type
                            WHEN 'public.bookable'   THEN 'parenthood'::claimius.tree_type
                         END;
    END IF;

    RETURN QUERY
    WITH combined AS (
        SELECT
            claimius.user_object.object_id           AS object_id,
            claimius.user_object.object_type         AS object_type,
            best.uc_id                               AS user_claim_id,
            claimius.user_object.sa_name             AS name,
            claimius.user_object.sa_description      AS description,
            claimius.user_object.sa_link             AS link,
            claimius.user_object.sa_access           AS sa_access,
            claimius.user_object.scope               AS scope,
            claimius.user_object.sa_owner_id         AS owner_id,
            claimius.user_object.sa_location_id      AS location_id,
            (claimius.user_object.direct_grant AND best.uc_id IS NULL) AS is_direct_grant,
            ts_rank(claimius.user_object.search_vector, v_tsquery)     AS rank
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
        WHERE v_include_others
          AND claimius.user_object.user_id = p_user_id
          AND claimius.user_object.app_id = p_app_id
          AND (claimius.user_object.sa_access & p_required_access) = p_required_access
          AND claimius.user_object.search_vector @@ v_tsquery
          AND (p_object_types IS NULL OR claimius.user_object.object_type = ANY(p_object_types))
          AND (p_object_ids IS NULL OR claimius.user_object.object_id = ANY(p_object_ids))
          AND (p_exclude_object_ids IS NULL OR NOT (claimius.user_object.object_id = ANY(p_exclude_object_ids)))
          AND (p_owner_subtree_ids IS NULL OR EXISTS (
              SELECT 1 FROM claimius.inheritance_info ii
              WHERE ii.tree_type       = 'ownership'
                AND ii.ancestor_type   = 'claimius.organization'
                AND ii.ancestor_id     = ANY(p_owner_subtree_ids)
                AND ii.descendant_type = claimius.user_object.object_type
                AND ii.descendant_id   = claimius.user_object.object_id
          ))
          AND (p_parent_id IS NULL OR v_parent_tree IS NULL OR EXISTS (
              SELECT 1 FROM claimius.inheritance_info ii
              WHERE ii.tree_type       = v_parent_tree
                AND ii.ancestor_type   = p_parent_type
                AND ii.ancestor_id     = p_parent_id
                AND ii.descendant_type = claimius.user_object.object_type
                AND ii.descendant_id   = claimius.user_object.object_id
          ))
          AND (p_type_ids IS NULL OR (
              claimius.user_object.object_type = 'public.bookable'
              AND EXISTS (
                  SELECT 1 FROM public.bookable b
                  WHERE b.id = claimius.user_object.object_id
                    AND b.type_id = ANY(p_type_ids)
                    AND b.sa_deleted_at IS NULL
              )
          ))
          AND (best.uc_id IS NOT NULL OR claimius.user_object.direct_grant)

        UNION ALL

        SELECT
            c.id                                                       AS object_id,
            'claimius.claim'::TEXT                                     AS object_type,
            uc.id                                                      AS user_claim_id,
            c.name                                                     AS name,
            c.description                                              AS description,
            NULL::TEXT                                                 AS link,
            c.sa_access                                                AS sa_access,
            NULL::JSONB                                                AS scope,
            c.sa_owner_id                                              AS owner_id,
            NULL::UUID                                                 AS location_id,
            TRUE                                                       AS is_direct_grant,
            ts_rank(to_tsvector('simple', coalesce(c.name, '') || ' ' || coalesce(c.description, '')), v_tsquery) AS rank
        FROM claimius.claim c
                 JOIN claimius.user_claim uc ON uc.claim_id = c.id
            AND uc.user_id = p_user_id
            AND uc.app_id = p_app_id
            AND uc.sa_deleted_at IS NULL
            AND (uc.starts_at IS NULL OR uc.starts_at <= now())
            AND (uc.ends_at IS NULL OR uc.ends_at > now())
        WHERE v_include_claim
          AND NOT v_has_scope
          AND c.app_id = p_app_id
          AND c.sa_deleted_at IS NULL
          AND (c.sa_access & p_required_access) = p_required_access
          AND to_tsvector('simple', coalesce(c.name, '') || ' ' || coalesce(c.description, '')) @@ v_tsquery
          AND (p_object_ids IS NULL OR c.id = ANY(p_object_ids))
          AND (p_exclude_object_ids IS NULL OR NOT (c.id = ANY(p_exclude_object_ids)))
    )
    SELECT combined.object_id,
           combined.object_type,
           combined.user_claim_id,
           combined.name,
           combined.description,
           combined.link,
           combined.sa_access,
           combined.scope,
           combined.owner_id,
           combined.location_id,
           combined.is_direct_grant,
           combined.rank,
           COUNT(*) OVER ()::INTEGER AS total_count
    FROM combined
    ORDER BY combined.rank DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.search(UUID, UUID, TEXT, TEXT[], INTEGER, UUID[], UUID[], UUID[], UUID, TEXT, UUID[], INTEGER, INTEGER) IS 'Full text search over accessible objects. Includes claimius.claim rows the user holds (skipped when any subtree/parent/type filter is set). p_owner_subtree_ids scopes via ownership tree. p_parent_id + p_parent_type scope via location or parenthood tree. p_type_ids restricts bookable rows to those whose type_id is in the set. total_count carries the un-capped match count for pagination.';


DROP FUNCTION IF EXISTS public.search(UUID, TEXT, TEXT[], INTEGER, INTEGER, INTEGER, UUID[], UUID[], UUID, UUID[], UUID[]);

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
    p_exclude_object_ids UUID[]  DEFAULT NULL,
    p_owner_subtree_ids  UUID[]  DEFAULT NULL,
    p_parent_id          UUID    DEFAULT NULL,
    p_parent_type        TEXT    DEFAULT NULL,
    p_type_ids           UUID[]  DEFAULT NULL
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
                rank            REAL,
                total_count     INTEGER
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
    v_parent_tree   claimius.tree_type;
BEGIN
    IF p_parent_type IS NOT NULL THEN
        v_parent_tree := CASE p_parent_type
                            WHEN 'claimius.location' THEN 'location'::claimius.tree_type
                            WHEN 'public.bookable'   THEN 'parenthood'::claimius.tree_type
                         END;
    END IF;

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
        ),
        deduped AS (
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
              AND (p_owner_subtree_ids IS NULL OR EXISTS (
                  SELECT 1 FROM claimius.inheritance_info ii
                  WHERE ii.tree_type       = 'ownership'
                    AND ii.ancestor_type   = 'claimius.organization'
                    AND ii.ancestor_id     = ANY(p_owner_subtree_ids)
                    AND ii.descendant_type = a.object_type
                    AND ii.descendant_id   = a.object_id
              ))
              AND (p_parent_id IS NULL OR v_parent_tree IS NULL OR EXISTS (
                  SELECT 1 FROM claimius.inheritance_info ii
                  WHERE ii.tree_type       = v_parent_tree
                    AND ii.ancestor_type   = p_parent_type
                    AND ii.ancestor_id     = p_parent_id
                    AND ii.descendant_type = a.object_type
                    AND ii.descendant_id   = a.object_id
              ))
              AND (p_type_ids IS NULL OR (
                  a.object_type = 'public.bookable'
                  AND EXISTS (
                      SELECT 1 FROM public.bookable b
                      WHERE b.id = a.object_id
                        AND b.type_id = ANY(p_type_ids)
                        AND b.sa_deleted_at IS NULL
                  )
              ))
              AND (p_claim_id IS NULL OR EXISTS (
                  SELECT 1
                  FROM claimius.get_claims(p_user_id, v_app_id, a.object_id, a.object_type) gc
                  WHERE gc.id = p_claim_id
              ))
            ORDER BY
                a.object_id,
                a.object_type,
                CASE WHEN v_tsq IS NULL THEN 0::REAL ELSE coalesce(ts_rank(si.search_vector, v_tsq), 0)::REAL END DESC
        )
        SELECT d.object_id,
               d.object_type,
               d.user_claim_id,
               d.name,
               d.description,
               d.link,
               d.sa_access,
               d.scope,
               d.owner_id,
               d.location_id,
               d.is_direct_grant,
               d.rank,
               COUNT(*) OVER ()::INTEGER AS total_count
        FROM deduped d
        ORDER BY d.rank DESC
        LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION public.search(UUID, TEXT, TEXT[], INTEGER, INTEGER, INTEGER, UUID[], UUID[], UUID, UUID[], UUID[], UUID[], UUID, TEXT, UUID[]) IS 'Search across public registered tables via claimius.get_objects. p_owner_subtree_ids scopes via ownership tree. p_parent_id + p_parent_type scope via location or parenthood tree. p_type_ids restricts bookable rows to those whose type_id is in the set. total_count carries the un-capped match count for pagination.';
