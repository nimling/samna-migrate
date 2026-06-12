CREATE OR REPLACE FUNCTION get_organizations(
    p_user_id   UUID,
    p_required_access INTEGER DEFAULT 0
)
    RETURNS SETOF claimius.organization
AS
$$
    SELECT * FROM claimius.get_organizations(p_user_id, claimius.get_disciple_app_id(), p_required_access);
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION get_locations(
    p_user_id   UUID,
    p_required_access INTEGER DEFAULT 0
)
    RETURNS SETOF claimius.location
AS
$$
    SELECT * FROM claimius.get_locations(p_user_id, claimius.get_disciple_app_id(), p_required_access);
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION get_users(
    p_user_id   UUID,
    p_required_access INTEGER DEFAULT 0
)
    RETURNS SETOF claimius.samna_user
AS
$$
    SELECT * FROM claimius.get_users(p_user_id, claimius.get_disciple_app_id(), p_required_access);
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION get_claims(
    p_user_id   UUID,
    p_required_access INTEGER DEFAULT 0
)
    RETURNS SETOF claimius.claim
AS
$$
    SELECT * FROM claimius.get_claims(p_user_id, claimius.get_disciple_app_id(), p_required_access);
$$ LANGUAGE sql STABLE;


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
                ELSE websearch_to_tsquery('english', p_query)
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
        AND (uo.sa_access & p_required_access) = p_required_access
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


CREATE OR REPLACE FUNCTION get_claim_objects(p_claim_id UUID)
    RETURNS TABLE (object_id UUID, object_type TEXT)
AS
$$
    SELECT co.object_id, co.object_type
    FROM claimius.claim_object co
    WHERE co.claim_id = p_claim_id AND co.sa_deleted_at IS NULL;
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION get_object_assets(object_id uuid)
    RETURNS TABLE
            (
                id            uuid,
                name          text,
                description   text,
                mime_type     text,
                sa_owner_id   uuid,
                sa_created_by uuid,
                status        text,
                index         int,
                sa_deleted_at timestamptz,
                sa_created_at timestamptz,
                sa_updated_at timestamptz
            )
AS
$$
BEGIN
    RETURN QUERY
        SELECT a.id,
               a.name,
               a.description,
               a.mime_type,
               a.sa_owner_id,
               a.sa_created_by,
               a.status,
               COALESCE(oa.index, a.index) AS index,
               a.sa_deleted_at,
               a.sa_created_at,
               a.sa_updated_at
        FROM asset a
                 JOIN
             object_asset oa ON oa.asset_id = a.id AND oa.object_id = get_object_assets.object_id
        WHERE a.sa_deleted_at IS NULL
          AND a.id IN (SELECT asset_id FROM object_asset oa WHERE oa.object_id = get_object_assets.object_id)
        ORDER BY index;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION get_organization_descendants(p_org_id UUID)
    RETURNS SETOF UUID
AS
$$
    WITH RECURSIVE descendants AS (
        SELECT id, sa_owner_id
        FROM claimius.organization
        WHERE id = p_org_id AND sa_deleted_at IS NULL
        UNION
        SELECT o.id, o.sa_owner_id
        FROM claimius.organization o
                 JOIN descendants d ON o.sa_owner_id = d.id AND o.id <> o.sa_owner_id
        WHERE o.sa_deleted_at IS NULL
    )
    SELECT id FROM descendants WHERE id <> p_org_id;
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION get_organization_ancestors(p_org_id UUID)
    RETURNS SETOF UUID
AS
$$
    WITH RECURSIVE ancestors AS (
        SELECT id, sa_owner_id
        FROM claimius.organization
        WHERE id = p_org_id AND sa_deleted_at IS NULL
        UNION
        SELECT o.id, o.sa_owner_id
        FROM claimius.organization o
                 JOIN ancestors a ON a.sa_owner_id = o.id AND a.id <> a.sa_owner_id
        WHERE o.sa_deleted_at IS NULL
    )
    SELECT id FROM ancestors WHERE id <> p_org_id;
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION get_location_descendants(p_location_id UUID)
    RETURNS SETOF UUID
AS
$$
    WITH RECURSIVE descendants AS (
        SELECT id, sa_parent_id
        FROM claimius.location
        WHERE id = p_location_id AND sa_deleted_at IS NULL
        UNION
        SELECT l.id, l.sa_parent_id
        FROM claimius.location l
                 JOIN descendants d ON l.sa_parent_id = d.id AND l.id <> l.sa_parent_id
        WHERE l.sa_deleted_at IS NULL
    )
    SELECT id FROM descendants WHERE id <> p_location_id;
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION get_bookable_descendants(p_bookable_id UUID)
    RETURNS SETOF UUID
AS
$$
    WITH RECURSIVE descendants AS (
        SELECT id, sa_parent_id
        FROM public.bookable
        WHERE id = p_bookable_id AND sa_deleted_at IS NULL
        UNION
        SELECT b.id, b.sa_parent_id
        FROM public.bookable b
                 JOIN descendants d ON b.sa_parent_id = d.id AND b.id <> b.sa_parent_id
        WHERE b.sa_deleted_at IS NULL
    )
    SELECT id FROM descendants WHERE id <> p_bookable_id;
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION get_booking_members(p_user_id UUID, p_booking_id UUID)
    RETURNS SETOF claimius.samna_user
AS
$$
BEGIN
    RETURN QUERY
        SELECT u.*
        FROM claimius.get_users(p_user_id, claimius.get_disciple_app_id(), 8) u
        WHERE EXISTS (
            SELECT 1 FROM claimius.get_access(u.user_id, claimius.get_disciple_app_id(), p_booking_id, 'public.booking', 8)
        );
END;
$$ LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION get_booking_owner_name(
    p_user_id  UUID,
    p_owner_id UUID,
    p_level    INTEGER DEFAULT 8
)
    RETURNS TEXT
AS
$$
DECLARE
    result TEXT;
BEGIN
    SELECT o.name
    INTO result
    FROM claimius.get_organizations(p_user_id, claimius.get_disciple_app_id(), p_level) o
    WHERE o.id = p_owner_id;

    RETURN COALESCE(result, 'inaccessible');
END;
$$ LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION get_booking_creator_email(
    p_user_id    UUID,
    p_created_by UUID,
    p_level      INTEGER DEFAULT 8
)
    RETURNS TEXT
AS
$$
DECLARE
    result          TEXT;
    creator_user_id UUID;
BEGIN
    SELECT uc.user_id
    INTO creator_user_id
    FROM claimius.user_claim uc
    WHERE uc.id = p_created_by AND uc.sa_deleted_at IS NULL;

    IF creator_user_id IS NULL THEN
        RETURN 'inaccessible';
    END IF;

    SELECT u.email
    INTO result
    FROM claimius.get_users(p_user_id, claimius.get_disciple_app_id(), p_level) u
    WHERE u.user_id = creator_user_id;

    RETURN COALESCE(result, 'inaccessible');
END;
$$ LANGUAGE plpgsql STABLE;
