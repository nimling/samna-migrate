CREATE OR REPLACE FUNCTION public.get_bookable_type_available_hours(
    p_user_id UUID,
    p_required_access INTEGER,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_organization_id UUID DEFAULT NULL
)
    RETURNS TABLE
            (
                bookable_type_id   UUID,
                bookable_type_name TEXT,
                total_hours        NUMERIC,
                used_hours         NUMERIC,
                available_hours    NUMERIC,
                utilization_rate   NUMERIC
            )
AS
$$
BEGIN
    RETURN QUERY
        WITH accessible_types AS (SELECT DISTINCT go.object_id AS bookable_type_id
                                  FROM claimius.get_objects(p_user_id, claimius.get_disciple_app_id(), 'public.bookable_type', p_required_access) go),
             org_hierarchy AS (SELECT d.object_id AS id
                               FROM claimius.get_descendants('claimius.organization', p_organization_id) d
                               WHERE p_organization_id IS NOT NULL
                                 AND d.tree_type   = 'ownership'
                                 AND d.object_type = 'claimius.organization'),
             organization_filter AS (SELECT bt.id   AS type_id,
                                            bt.name AS type_name
                                     FROM public.bookable_type bt
                                     WHERE bt.id IN (SELECT accessible_types.bookable_type_id FROM accessible_types)
                                       AND bt.sa_deleted_at IS NULL
                                       AND (p_organization_id IS NULL OR
                                            bt.sa_owner_id IN (SELECT oh.id FROM org_hierarchy oh))),
             type_bookables AS (SELECT bt.type_id,
                                       bt.type_name,
                                       b.id AS bookable_id
                                FROM organization_filter bt
                                         JOIN public.bookable b ON b.type_id = bt.type_id
                                WHERE b.sa_deleted_at IS NULL
                                  AND b.id IN (SELECT go.object_id FROM claimius.get_objects(p_user_id, claimius.get_disciple_app_id(), 'public.bookable', p_required_access) go)),
             bookable_stats AS (SELECT tb.type_id,
                                       tb.type_name,
                                       COALESCE(SUM(
                                                        (SELECT bh.available_hours
                                                         FROM public.get_bookable_available_hours(tb.bookable_id, p_start_date,
                                                                                           p_end_date) bh)
                                                ), 0) AS available_hours,
                                       COALESCE(SUM(
                                                        (SELECT bh.used_hours
                                                         FROM public.get_bookable_available_hours(tb.bookable_id, p_start_date,
                                                                                           p_end_date) bh)
                                                ), 0) AS used_hours
                                FROM type_bookables tb
                                GROUP BY tb.type_id, tb.type_name)
        SELECT bs.type_id                           AS bookable_type_id,
               bs.type_name                         AS bookable_type_name,
               (bs.available_hours + bs.used_hours) AS total_hours,
               bs.used_hours,
               bs.available_hours,
               CASE
                   WHEN (bs.available_hours + bs.used_hours) > 0
                       THEN (bs.used_hours / (bs.available_hours + bs.used_hours) * 100)::NUMERIC
                   ELSE 0::NUMERIC
                   END                              AS utilization_rate
        FROM bookable_stats bs
        ORDER BY total_hours DESC;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION public.get_organization_available_hours(
    p_organization_id UUID,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
    RETURNS TABLE
            (
                organization_id   UUID,
                organization_name TEXT,
                total_hours       NUMERIC,
                used_hours        NUMERIC,
                available_hours   NUMERIC,
                utilization_rate  NUMERIC
            )
AS
$$
BEGIN
    RETURN QUERY
        WITH org_hierarchy AS (SELECT o.id, o.name::TEXT AS name
                               FROM claimius.organization o
                                        JOIN claimius.get_descendants('claimius.organization', p_organization_id) d
                                             ON d.object_id   = o.id
                                            AND d.tree_type   = 'ownership'
                                            AND d.object_type = 'claimius.organization'
                               WHERE o.sa_deleted_at IS NULL),
             org_bookables AS (SELECT org.id   AS organization_id,
                                      org.name AS organization_name,
                                      b.id     AS bookable_id
                               FROM org_hierarchy org
                                        JOIN public.bookable b ON b.sa_owner_id = org.id
                               WHERE b.sa_deleted_at IS NULL),
             bookable_stats AS (SELECT ob.organization_id,
                                       ob.organization_name,
                                       SUM((SELECT bh.available_hours
                                            FROM public.get_bookable_available_hours(ob.bookable_id, p_start_date,
                                                                              p_end_date) bh)) AS available_hours,
                                       SUM((SELECT bh.used_hours
                                            FROM public.get_bookable_available_hours(ob.bookable_id, p_start_date,
                                                                              p_end_date) bh)) AS used_hours
                                FROM org_bookables ob
                                GROUP BY ob.organization_id, ob.organization_name)
        SELECT bs.organization_id,
               bs.organization_name,
               (bs.available_hours + bs.used_hours) AS total_hours,
               bs.used_hours,
               bs.available_hours,
               CASE
                   WHEN (bs.available_hours + bs.used_hours) > 0
                       THEN (bs.used_hours / (bs.available_hours + bs.used_hours) * 100)::NUMERIC
                   ELSE 0::NUMERIC
                   END                              AS utilization_rate
        FROM bookable_stats bs
        ORDER BY bs.organization_name;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION public.get_location_available_hours(
    p_location_id UUID,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
    RETURNS TABLE
            (
                location_id      UUID,
                location_name    TEXT,
                total_hours      NUMERIC,
                used_hours       NUMERIC,
                available_hours  NUMERIC,
                utilization_rate NUMERIC
            )
AS
$$
BEGIN
    RETURN QUERY
        WITH loc_hierarchy AS (SELECT l.id, l.name::TEXT AS name
                               FROM claimius.location l
                                        JOIN claimius.get_descendants('claimius.location', p_location_id) d
                                             ON d.object_id   = l.id
                                            AND d.tree_type   = 'location'
                                            AND d.object_type = 'claimius.location'
                               WHERE l.sa_deleted_at IS NULL),
             location_bookables AS (SELECT loc.id   AS location_id,
                                           loc.name AS location_name,
                                           b.id     AS bookable_id
                                    FROM loc_hierarchy loc
                                             JOIN public.bookable b ON b.sa_location_id = loc.id
                                    WHERE b.sa_deleted_at IS NULL),
             bookable_stats AS (SELECT lb.location_id,
                                       lb.location_name,
                                       SUM((SELECT bh.available_hours
                                            FROM public.get_bookable_available_hours(lb.bookable_id, p_start_date,
                                                                              p_end_date) bh)) AS available_hours,
                                       SUM((SELECT bh.used_hours
                                            FROM public.get_bookable_available_hours(lb.bookable_id, p_start_date,
                                                                              p_end_date) bh)) AS used_hours
                                FROM location_bookables lb
                                GROUP BY lb.location_id, lb.location_name)
        SELECT bs.location_id,
               bs.location_name,
               (bs.available_hours + bs.used_hours) AS total_hours,
               bs.used_hours,
               bs.available_hours,
               CASE
                   WHEN (bs.available_hours + bs.used_hours) > 0
                       THEN (bs.used_hours / (bs.available_hours + bs.used_hours) * 100)::NUMERIC
                   ELSE 0::NUMERIC
                   END                              AS utilization_rate
        FROM bookable_stats bs
        ORDER BY bs.location_name;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION public.search(
    p_user_id         UUID,
    p_query           TEXT    DEFAULT NULL,
    p_object_types    TEXT[]  DEFAULT NULL,
    p_required_access INTEGER DEFAULT 0,
    p_limit           INTEGER DEFAULT 20,
    p_offset          INTEGER DEFAULT 0,
    p_owner_ids       UUID[]  DEFAULT NULL,
    p_location_ids    UUID[]  DEFAULT NULL,
    p_claim_id        UUID    DEFAULT NULL
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


DROP FUNCTION IF EXISTS public.get_organization_ancestors(UUID);
DROP FUNCTION IF EXISTS public.get_organization_descendants(UUID);
DROP FUNCTION IF EXISTS public.get_location_descendants(UUID);
DROP FUNCTION IF EXISTS public.get_bookable_descendants(UUID);
DROP FUNCTION IF EXISTS public.get_location_ancestors(UUID);
