ALTER TABLE timeslot ADD COLUMN IF NOT EXISTS conditions JSONB DEFAULT NULL;

DROP FUNCTION IF EXISTS claimius.search(UUID, UUID, TEXT, TEXT[], INTEGER, UUID[], UUID[], INTEGER, INTEGER);

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
    v_tsquery        TSQUERY;
    v_include_claim  BOOLEAN := p_object_types IS NULL OR 'claimius.claim' = ANY(p_object_types);
    v_include_others BOOLEAN := p_object_types IS NULL OR EXISTS (
        SELECT 1 FROM unnest(p_object_types) t WHERE t <> 'claimius.claim'
    );
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    v_tsquery := websearch_to_tsquery('simple', p_query);

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
           combined.rank
    FROM combined
    ORDER BY combined.rank DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.search(UUID, UUID, TEXT, TEXT[], INTEGER, UUID[], UUID[], INTEGER, INTEGER) IS 'Full text search over accessible objects whose mask covers p_required_access. user_claim_id is the actor token from the strongest surviving claim grant per object. Also includes claimius.claim rows the user holds. p_object_ids and p_exclude_object_ids filter by object_id at the SQL layer.';


DROP FUNCTION IF EXISTS claimius.create_claim(UUID, TEXT, TEXT, INTEGER, UUID, UUID, UUID, BOOLEAN, claimius.claim_type);

CREATE OR REPLACE FUNCTION claimius.create_claim(
    p_app_id            UUID,
    p_name              TEXT,
    p_description       TEXT,
    p_sa_access         INTEGER,
    p_sa_owner_id       UUID,
    p_sa_root_id        UUID,
    p_sa_created_by     UUID,
    p_inherits          BOOLEAN DEFAULT TRUE,
    p_type              claimius.claim_type DEFAULT 'user'
) RETURNS JSONB AS $$
DECLARE
    v_row    claimius.claim;
    v_access INTEGER := p_sa_access;
BEGIN
    IF (v_access & 1) = 1 THEN
        v_access := v_access | 14;
    END IF;
    IF (v_access & 2) = 2 THEN
        v_access := v_access | 12;
    END IF;
    IF (v_access & 8) = 8 THEN
        v_access := v_access | 4;
    END IF;

    INSERT INTO claimius.claim (
        app_id, name, description, sa_access, inherits, type,
        sa_owner_id, sa_root_id, sa_created_by
    ) VALUES (
                 p_app_id, p_name, p_description, v_access, p_inherits, p_type,
                 p_sa_owner_id, p_sa_root_id, p_sa_created_by
             ) RETURNING * INTO v_row;
    RETURN jsonb_build_object('claim', to_jsonb(v_row));
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.create_claim IS 'Creates a new claim. p_sa_access is a bitwise mask: 0x01 owner, 0x02 write, 0x04 read, 0x08 execute, 0x10 deny. Owner implies write+read+execute. Write implies read+execute. Execute implies read.';


DROP FUNCTION IF EXISTS claimius.update_claim(UUID, TEXT, TEXT, INTEGER, BOOLEAN);

CREATE OR REPLACE FUNCTION claimius.update_claim(
    p_claim_id          UUID,
    p_name              TEXT DEFAULT NULL,
    p_description       TEXT DEFAULT NULL,
    p_sa_access         INTEGER DEFAULT NULL,
    p_inherits          BOOLEAN DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_row    claimius.claim;
    v_access INTEGER := p_sa_access;
BEGIN
    IF v_access IS NOT NULL THEN
        IF (v_access & 1) = 1 THEN
            v_access := v_access | 14;
        END IF;
        IF (v_access & 2) = 2 THEN
            v_access := v_access | 12;
        END IF;
        IF (v_access & 8) = 8 THEN
            v_access := v_access | 4;
        END IF;
    END IF;

    UPDATE claimius.claim SET
                              name        = coalesce(NULLIF(p_name, ''), name),
                              description = coalesce(p_description, description),
                              sa_access   = coalesce(NULLIF(v_access, 0), sa_access),
                              inherits    = coalesce(p_inherits, inherits)
    WHERE id = p_claim_id
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('claim', to_jsonb(v_row));
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.update_claim IS 'Patches selected fields on a claim. p_sa_access is expanded so owner implies write+read+execute, write implies read+execute, execute implies read. Empty p_name and zero p_sa_access are treated as preserve so PATCH callers that send only one field do not wipe the others.';

UPDATE claimius.claim SET sa_access = sa_access | 14 WHERE (sa_access & 1) = 1 AND sa_deleted_at IS NULL;
UPDATE claimius.claim SET sa_access = sa_access | 12 WHERE (sa_access & 2) = 2 AND sa_deleted_at IS NULL;
UPDATE claimius.claim SET sa_access = sa_access |  4 WHERE (sa_access & 8) = 8 AND sa_deleted_at IS NULL;

DROP FUNCTION IF EXISTS claimius.remove_claim(UUID, UUID);

CREATE OR REPLACE FUNCTION claimius.remove_claim(
    p_claim_id      UUID,
    p_deleted_by    UUID
) RETURNS SETOF claimius.claim AS $$
BEGIN
    UPDATE claimius.user_claim SET sa_deleted_at = now() WHERE claim_id = p_claim_id AND sa_deleted_at IS NULL;
    UPDATE claimius.claim_object SET sa_deleted_at = now() WHERE claim_id = p_claim_id AND sa_deleted_at IS NULL;
    RETURN QUERY
    UPDATE claimius.claim SET sa_deleted_at = now()
    WHERE id = p_claim_id AND sa_deleted_at IS NULL
    RETURNING *;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.remove_claim IS 'Soft deletes a claim and cascades user_claim and claim_object rows. Returns the deleted claim row.';

DROP FUNCTION IF EXISTS claimius.remove_user_claim(UUID, UUID);

CREATE OR REPLACE FUNCTION claimius.remove_user_claim(
    p_user_claim_id UUID,
    p_deleted_by    UUID
) RETURNS SETOF claimius.user_claim AS $$
BEGIN
    RETURN QUERY
    UPDATE claimius.user_claim SET sa_deleted_at = now()
    WHERE id = p_user_claim_id AND sa_deleted_at IS NULL
    RETURNING *;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.remove_user_claim IS 'Soft deletes a user_claim row. Returns the deleted user_claim row.';

DROP FUNCTION IF EXISTS claimius.remove_claim_object(UUID, UUID);

CREATE OR REPLACE FUNCTION claimius.remove_claim_object(
    p_claim_object_id UUID,
    p_deleted_by      UUID
) RETURNS SETOF claimius.claim_object AS $$
BEGIN
    RETURN QUERY
    UPDATE claimius.claim_object SET sa_deleted_at = now()
    WHERE id = p_claim_object_id AND sa_deleted_at IS NULL
    RETURNING *;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.remove_claim_object IS 'Soft deletes a claim_object row. Returns the deleted claim_object row.';
