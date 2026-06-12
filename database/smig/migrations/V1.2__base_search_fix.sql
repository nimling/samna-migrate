CREATE OR REPLACE FUNCTION tg_search_index()
RETURNS TRIGGER AS $$
DECLARE
    v_vector TSVECTOR;
BEGIN
    IF TG_OP = 'DELETE' THEN
        DELETE FROM search_index
        WHERE object_id = OLD.id AND object_type = TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
        RETURN OLD;
    END IF;

    v_vector := setweight(to_tsvector('simple', COALESCE(NEW.name, '')), 'A') ||
                setweight(to_tsvector('simple', COALESCE(NEW.description, '')), 'B');

    INSERT INTO search_index (object_id, object_type, search_vector)
    VALUES (NEW.id, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_vector)
    ON CONFLICT (object_id, object_type) DO UPDATE
    SET search_vector = EXCLUDED.search_vector;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

UPDATE search_index si
SET search_vector = (
    SELECT
        setweight(to_tsvector('simple', COALESCE(b.name, '')), 'A') ||
        setweight(to_tsvector('simple', COALESCE(b.description, '')), 'B')
    FROM bookable b WHERE b.id = si.object_id
)
WHERE si.object_type = 'public.bookable';

UPDATE search_index si
SET search_vector = (
    SELECT
        setweight(to_tsvector('simple', COALESCE(b.name, '')), 'A') ||
        setweight(to_tsvector('simple', COALESCE(b.description, '')), 'B')
    FROM booking b WHERE b.id = si.object_id
)
WHERE si.object_type = 'public.booking';

UPDATE search_index si
SET search_vector = (
    SELECT
        setweight(to_tsvector('simple', COALESCE(t.name, '')), 'A') ||
        setweight(to_tsvector('simple', COALESCE(t.description, '')), 'B')
    FROM timeslot t WHERE t.id = si.object_id
)
WHERE si.object_type = 'public.timeslot';

UPDATE search_index si
SET search_vector = (
    SELECT
        setweight(to_tsvector('simple', COALESCE(bt.name, '')), 'A') ||
        setweight(to_tsvector('simple', COALESCE(bt.description, '')), 'B')
    FROM bookable_type bt WHERE bt.id = si.object_id
)
WHERE si.object_type = 'public.bookable_type';

UPDATE search_index si
SET search_vector = (
    SELECT
        setweight(to_tsvector('simple', COALESCE(c.name, '')), 'A') ||
        setweight(to_tsvector('simple', COALESCE(c.description, '')), 'B')
    FROM capability c WHERE c.id = si.object_id
)
WHERE si.object_type = 'public.capability';

UPDATE search_index si
SET search_vector = (
    SELECT
        setweight(to_tsvector('simple', COALESCE(a.name, '')), 'A') ||
        setweight(to_tsvector('simple', COALESCE(a.description, '')), 'B')
    FROM asset a WHERE a.id = si.object_id
)
WHERE si.object_type = 'public.asset';

UPDATE search_index si
SET search_vector = (
    SELECT
        setweight(to_tsvector('simple', COALESCE(c.name, '')), 'A') ||
        setweight(to_tsvector('simple', COALESCE(c.description, '')), 'B')
    FROM code c WHERE c.id = si.object_id
)
WHERE si.object_type = 'public.code';

CREATE OR REPLACE FUNCTION search(
    p_user_id      UUID,
    p_query        TEXT          DEFAULT NULL,
    p_object_types TEXT[]        DEFAULT NULL,
    p_required_access INTEGER DEFAULT 0,
    p_limit        INTEGER       DEFAULT 20,
    p_offset       INTEGER       DEFAULT 0,
    p_owner_ids    UUID[]        DEFAULT NULL,
    p_location_ids UUID[]        DEFAULT NULL,
    p_claim_id     UUID          DEFAULT NULL
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
    WITH q AS (
        SELECT
            CASE
                WHEN p_query IS NULL OR length(btrim(p_query)) = 0 THEN NULL
                ELSE to_tsquery('simple',
                    array_to_string(
                        ARRAY(
                            SELECT lower(btrim(word)) || ':*'
                            FROM regexp_split_to_table(btrim(p_query), '\s+') word
                            WHERE length(btrim(word)) > 0
                        ),
                        ' & '
                    )
                )
            END AS tsq
    )
    SELECT
        uo.object_id,
        uo.object_type,
        best.uc_id,
        uo.sa_name,
        uo.sa_description,
        uo.sa_link,
        uo.sa_access,
        uo.scope,
        uo.sa_owner_id,
        uo.sa_location_id,
        (uo.direct_grant AND best.uc_id IS NULL),
        CASE WHEN q.tsq IS NULL THEN 0::REAL ELSE COALESCE(ts_rank(si.search_vector, q.tsq), 0)::REAL END
    FROM claimius.user_object uo
    CROSS JOIN q
    LEFT JOIN public.search_index si
        ON si.object_id = uo.object_id
        AND si.object_type = uo.object_type
    LEFT JOIN LATERAL (
        SELECT uc.id AS uc_id
        FROM jsonb_array_elements(uo.grants) g
            JOIN claimius.user_claim uc ON uc.claim_id = (g ->> 'claim_id')::UUID
                AND uc.user_id = p_user_id
                AND uc.app_id = claimius.get_disciple_app_id()
                AND uc.sa_deleted_at IS NULL
                AND (uc.starts_at IS NULL OR uc.starts_at <= now())
                AND (uc.ends_at IS NULL OR uc.ends_at > now())
            JOIN claimius.claim c ON c.id = uc.claim_id AND c.sa_deleted_at IS NULL
        ORDER BY (g ->> 'level')::INTEGER ASC
        LIMIT 1
    ) best ON TRUE
    WHERE uo.app_id = claimius.get_disciple_app_id()
        AND uo.user_id = p_user_id
        AND (p_required_access = 0 OR uo.sa_access <= p_required_access)
        AND (p_object_types IS NULL OR uo.object_type = ANY(p_object_types))
        AND (p_owner_ids IS NULL OR uo.sa_owner_id = ANY(p_owner_ids))
        AND (p_location_ids IS NULL OR uo.sa_location_id = ANY(p_location_ids))
        AND (best.uc_id IS NOT NULL OR uo.direct_grant)
        AND (q.tsq IS NULL OR (si.search_vector IS NOT NULL AND si.search_vector @@ q.tsq))
        AND (p_claim_id IS NULL OR EXISTS (
            SELECT 1 FROM claimius.claim_object co
            WHERE co.claim_id = p_claim_id
              AND co.object_id = uo.object_id
              AND co.object_type = uo.object_type
              AND co.sa_deleted_at IS NULL
        ))
    ORDER BY
        CASE WHEN q.tsq IS NULL THEN 0::REAL ELSE COALESCE(ts_rank(si.search_vector, q.tsq), 0)::REAL END DESC,
        uo.sa_updated_at DESC
    LIMIT p_limit OFFSET p_offset;
$$ LANGUAGE sql STABLE;
