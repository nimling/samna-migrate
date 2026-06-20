-- ============================================================================
-- Claimius V2.4 External Functions
-- ----------------------------------------------------------------------------
-- The public surface. All consumer reads go through these. Direct table
-- queries are forbidden by the role grant model: claimius_reader and
-- claimius_disciple_client only have EXECUTE on these functions.
--
-- Every read function:
--   1. Calls reconcile_if_pending to drain any pending disciple side queue
--   2. Calls check_user_active which cascades soft delete if applicable
--   3. Filters by sa_deleted_at and time validity (starts_at, ends_at)
--   4. Returns the result
-- ============================================================================

-- ----------------------------------------------------------------------------
-- get_access
-- Returns the surviving grant the user has against one object whose
-- effective access mask covers all bits in p_required_access. Joins
-- user_object grants array against user_claim and claim, filters by
-- sa_deleted_at and time validity. Returns one row, picking the grant
-- whose access mask carries the most bits set.
--
-- Contract: when claim_id is non-null, user_claim_id is also populated. This
-- is the actor token callers use as sa_created_by on follow-on writes.
-- When direct_grant is true and claim_id is null, user_claim_id is also null;
-- callers needing an actor for direct-only access must resolve a fallback
-- user_claim themselves (typically the user's bootstrap user_claim for the app).
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS claimius.get_access(UUID, UUID, UUID, TEXT, INTEGER);

CREATE OR REPLACE FUNCTION claimius.get_access(
    p_user_id          UUID,
    p_app_id           UUID,
    p_object_id        UUID,
    p_object_type      TEXT,
    p_required_access  INTEGER DEFAULT 0
) RETURNS TABLE (
                    user_object_id      UUID,
                    user_claim_id       UUID,
                    claim_id            UUID,
                    sa_access           INTEGER,
                    scope               JSONB,
                    sa_owner_id         UUID,
                    sa_root_id          UUID,
                    sa_location_id      UUID,
                    direct_grant        BOOLEAN
                ) AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
        WITH uo AS (
            SELECT u.*
            FROM claimius.user_object u
            WHERE u.user_id = p_user_id
              AND u.app_id = p_app_id
              AND u.object_id = p_object_id
              AND u.object_type = p_object_type
              AND (u.sa_access & p_required_access) = p_required_access
        ),
             surviving AS (
                 SELECT
                     uo.id AS user_object_id,
                     uc.id AS user_claim_id,
                     (g ->> 'claim_id')::UUID AS claim_id,
                     (g ->> 'access')::INTEGER AS access_bits,
                     g -> 'scope' AS grant_scope,
                     uo.sa_owner_id,
                     uo.sa_root_id,
                     uo.sa_location_id,
                     FALSE AS direct_grant
                 FROM uo
                          CROSS JOIN LATERAL jsonb_array_elements(uo.grants) g
                          JOIN claimius.user_claim uc ON uc.claim_id = (g ->> 'claim_id')::UUID
                     AND uc.user_id = p_user_id
                     AND uc.app_id = p_app_id
                     AND uc.sa_deleted_at IS NULL
                     AND (uc.starts_at IS NULL OR uc.starts_at <= now())
                     AND (uc.ends_at IS NULL OR uc.ends_at > now())
                          JOIN claimius.claim c ON c.id = uc.claim_id
                     AND c.sa_deleted_at IS NULL
                 WHERE ((g ->> 'access')::INTEGER & p_required_access) = p_required_access
             )
        SELECT s.user_object_id, s.user_claim_id, s.claim_id, s.access_bits,
               s.grant_scope, s.sa_owner_id, s.sa_root_id, s.sa_location_id, s.direct_grant
        FROM surviving s
        ORDER BY claimius._popcount(s.access_bits) DESC, s.access_bits DESC
        LIMIT 1;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_access(UUID, UUID, UUID, TEXT, INTEGER) IS 'Strongest active claim based grant for one (user, app, object) whose mask covers p_required_access. user_claim_id is the actor token for follow-on writes.';

-- ----------------------------------------------------------------------------
-- get_direct_access
-- Locates the closest, highest-privilege user_claim the calling user holds
-- that's structurally related to the given object. Walks the owner,
-- location, and parenthood ancestor chains; for each ancestor checks
-- whether the user has any user_claim bound to it via claim_object.
-- Returns the same row shape as get_access (user_object_id, user_claim_id,
-- claim_id, sa_access, scope, sa_owner_id, sa_root_id, sa_location_id,
-- direct_grant). Returns no rows when no claim is found anywhere up the
-- chain, which means the user has no access through the structural lookup.
--
-- Use this when get_access returns no row but the caller still expects an
-- actor token via the user's structural relationship to the object. In
-- normal flow, every resource should have a direct claim_object binding
-- (the owner claim rule), so this lookup mostly serves edge cases.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS claimius.get_direct_access(UUID, UUID, UUID, TEXT);

CREATE OR REPLACE FUNCTION claimius.get_direct_access(
    p_user_id       UUID,
    p_app_id        UUID,
    p_object_id     UUID,
    p_object_type   TEXT
) RETURNS TABLE (
                    user_object_id      UUID,
                    user_claim_id       UUID,
                    claim_id            UUID,
                    sa_access           INTEGER,
                    scope               JSONB,
                    sa_owner_id         UUID,
                    sa_root_id          UUID,
                    sa_location_id      UUID,
                    direct_grant        BOOLEAN
                ) AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    IF p_object_type = 'claimius.samna_user' AND p_object_id = p_user_id THEN
        RETURN QUERY
            SELECT
                claimius.composite_id(p_app_id::TEXT, p_user_id::TEXT, p_object_type, p_object_id::TEXT),
                uc.id,
                uc.claim_id,
                15,
                NULL::JSONB,
                uc.sa_owner_id,
                c.sa_root_id,
                NULL::UUID,
                TRUE
            FROM claimius.user_claim uc
            JOIN claimius.claim c
              ON c.id = uc.claim_id
             AND c.sa_deleted_at IS NULL
            WHERE uc.user_id = p_user_id
              AND uc.app_id = p_app_id
              AND uc.sa_deleted_at IS NULL
              AND (uc.starts_at IS NULL OR uc.starts_at <= now())
              AND (uc.ends_at IS NULL OR uc.ends_at > now())
            ORDER BY uc.sa_created_at ASC
            LIMIT 1;
        RETURN;
    END IF;

    RETURN QUERY
        SELECT
            claimius.composite_id(p_app_id::TEXT, p_user_id::TEXT, p_object_type, p_object_id::TEXT),
            uc.id,
            c.id,
            (c.sa_access | co.sa_access) & 15,
            co.scope,
            co.sa_owner_id,
            co.sa_root_id,
            NULL::UUID,
            FALSE
        FROM claimius.get_ancestors(p_object_type, p_object_id) a
                 JOIN claimius.claim_object co
                      ON co.app_id = p_app_id
                          AND co.object_type = a.object_type
                          AND co.object_id = a.object_id
                          AND co.sa_deleted_at IS NULL
                 JOIN claimius.user_claim uc
                      ON uc.claim_id = co.claim_id
                          AND uc.user_id = p_user_id
                          AND uc.app_id = p_app_id
                          AND uc.sa_deleted_at IS NULL
                          AND (uc.starts_at IS NULL OR uc.starts_at <= now())
                          AND (uc.ends_at IS NULL OR uc.ends_at > now())
                 JOIN claimius.claim c
                      ON c.id = uc.claim_id
                          AND c.sa_deleted_at IS NULL
                          AND ((c.sa_access | co.sa_access) & 16) = 0
        ORDER BY a.hop ASC, claimius._popcount((c.sa_access | co.sa_access) & 15) DESC, uc.id ASC
        LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION claimius.get_direct_access(UUID, UUID, UUID, TEXT) IS 'Locates the closest, strongest user_claim the user holds related to the given object via ancestor walk. Skips deny bindings.';

-- ----------------------------------------------------------------------------
-- get_objects
-- Returns object ids of the given object_type whose effective access mask
-- covers all bits in p_required_access. The default 0 returns every object
-- the user has any access to.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS claimius.get_objects(UUID, UUID, TEXT, INTEGER);

CREATE OR REPLACE FUNCTION claimius.get_objects(
    p_user_id          UUID,
    p_app_id           UUID,
    p_object_type      TEXT,
    p_required_access  INTEGER DEFAULT 0
) RETURNS TABLE(
                   object_id           UUID,
                   user_claim_id       UUID,
                   sa_access           INTEGER,
                   scope               JSONB,
                   sa_owner_id         UUID,
                   sa_location_id      UUID,
                   sa_root_id          UUID,
                   sa_name             TEXT,
                   sa_description      TEXT,
                   sa_link             TEXT,
                   direct_grant        BOOLEAN
               ) AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    -- For each (user, object) row, pick the surviving claim grant whose
    -- access mask carries the most bits, restricted to grants that cover
    -- the required access bits. If only direct_grant applies,
    -- user_claim_id is null and direct_grant is true.
    RETURN QUERY
        SELECT
            claimius.user_object.object_id,
            best.uc_id,
            claimius.user_object.sa_access,
            claimius.user_object.scope,
            claimius.user_object.sa_owner_id,
            claimius.user_object.sa_location_id,
            claimius.user_object.sa_root_id,
            claimius.user_object.sa_name,
            claimius.user_object.sa_description,
            claimius.user_object.sa_link,
            (claimius.user_object.direct_grant AND best.uc_id IS NULL)
        FROM claimius.user_object
                 LEFT JOIN LATERAL (
            SELECT uc.id AS uc_id, (g ->> 'access')::INTEGER AS access_bits
            FROM jsonb_array_elements(claimius.user_object.grants) g
                     JOIN claimius.user_claim uc ON uc.claim_id = (g ->> 'claim_id')::UUID
                AND uc.user_id = p_user_id
                AND uc.app_id = p_app_id
                AND uc.sa_deleted_at IS NULL
                AND (uc.starts_at IS NULL OR uc.starts_at <= now())
                AND (uc.ends_at IS NULL OR uc.ends_at > now())
                     JOIN claimius.claim c ON c.id = uc.claim_id AND c.sa_deleted_at IS NULL
            WHERE ((g ->> 'access')::INTEGER & p_required_access) = p_required_access
            ORDER BY claimius._popcount((g ->> 'access')::INTEGER) DESC, (g ->> 'access')::INTEGER DESC
            LIMIT 1
            ) best ON TRUE
        WHERE claimius.user_object.user_id = p_user_id
          AND claimius.user_object.app_id = p_app_id
          AND claimius.user_object.object_type = p_object_type
          AND (claimius.user_object.sa_access & p_required_access) = p_required_access
          AND (best.uc_id IS NOT NULL OR claimius.user_object.direct_grant)
        ORDER BY claimius._popcount(claimius.user_object.sa_access) DESC, claimius.user_object.object_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_objects(p_user_id uuid, p_app_id uuid, p_object_type text, p_required_access integer) IS 'Object ids and metadata for objects whose mask covers p_required_access. user_claim_id is the actor token from the strongest surviving claim grant; null when only direct_grant applies.';

-- ----------------------------------------------------------------------------
-- get_organizations
-- Returns organizations whose mask covers p_required_access.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS claimius.get_organizations(UUID, UUID, INTEGER);

CREATE OR REPLACE FUNCTION claimius.get_organizations(
    p_user_id          UUID,
    p_app_id           UUID,
    p_required_access  INTEGER DEFAULT 0
) RETURNS SETOF claimius.organization AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
        SELECT o.*
        FROM claimius.organization o
        WHERE o.app_id = p_app_id
          AND o.sa_deleted_at IS NULL
          AND o.id IN (
            SELECT g.object_id FROM claimius.get_objects(p_user_id, p_app_id, 'claimius.organization', p_required_access) g
        );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_organizations(p_user_id uuid, p_app_id uuid, p_required_access integer) IS 'Organizations whose effective mask covers p_required_access.';

-- ----------------------------------------------------------------------------
-- get_locations
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS claimius.get_locations(UUID, UUID, INTEGER);

CREATE OR REPLACE FUNCTION claimius.get_locations(
    p_user_id          UUID,
    p_app_id           UUID,
    p_required_access  INTEGER DEFAULT 0
) RETURNS SETOF claimius.location AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
        SELECT l.*
        FROM claimius.location l
        WHERE l.app_id = p_app_id
          AND l.sa_deleted_at IS NULL
          AND l.id IN (
            SELECT g.object_id FROM claimius.get_objects(p_user_id, p_app_id, 'claimius.location', p_required_access) g
        );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_locations(p_user_id uuid, p_app_id uuid, p_required_access integer) IS 'Locations whose effective mask covers p_required_access.';

-- ----------------------------------------------------------------------------
-- get_users
-- Returns the users this user can see in this app: themselves, users they
-- hold direct claims on, plus users who share any object with them via
-- user_users.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS claimius.get_users(UUID, UUID, INTEGER);

CREATE OR REPLACE FUNCTION claimius.get_users(
    p_user_id          UUID,
    p_app_id           UUID,
    p_required_access  INTEGER DEFAULT 0
) RETURNS SETOF claimius.samna_user AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
        SELECT u.*
        FROM claimius.samna_user u
        WHERE u.app_id = p_app_id
          AND u.sa_deleted_at IS NULL
          AND u.status = 'active'
          AND (
            u.user_id = p_user_id
                OR u.user_id IN (
                SELECT target_user_id FROM claimius.user_users
                WHERE app_id = p_app_id AND viewer_id = p_user_id
            )
                OR u.user_id IN (
                SELECT g.object_id FROM claimius.get_objects(p_user_id, p_app_id, 'claimius.samna_user', p_required_access) g
            )
            );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_users(p_user_id uuid, p_app_id uuid, p_required_access integer) IS 'Users the calling user can see in this app.';

-- ----------------------------------------------------------------------------
-- get_claims (overload: by user)
-- Returns every claim the user holds whose access mask covers
-- p_required_access.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS claimius.get_claims(UUID, UUID, INTEGER);

CREATE OR REPLACE FUNCTION claimius.get_claims(
    p_user_id          UUID,
    p_app_id           UUID,
    p_required_access  INTEGER DEFAULT 0
) RETURNS SETOF claimius.claim AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
        SELECT c.*
        FROM claimius.claim c
                 JOIN claimius.user_claim uc ON uc.claim_id = c.id
        WHERE uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.sa_deleted_at IS NULL
          AND (uc.starts_at IS NULL OR uc.starts_at <= now())
          AND (uc.ends_at IS NULL OR uc.ends_at > now())
          AND c.sa_deleted_at IS NULL
          AND (c.sa_access & p_required_access) = p_required_access
        ORDER BY claimius._popcount(c.sa_access) DESC;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_claims(UUID, UUID, INTEGER) IS 'All claims the user holds whose mask covers p_required_access.';

-- ----------------------------------------------------------------------------
-- get_claims (overload: against an object)
-- Returns every claim the user holds against one object.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.get_claims(
    p_user_id       UUID,
    p_app_id        UUID,
    p_object_id     UUID,
    p_object_type   TEXT
) RETURNS SETOF claimius.claim AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
        SELECT DISTINCT c.*
        FROM claimius.user_object uo
                 CROSS JOIN LATERAL jsonb_array_elements(uo.grants) g
                 JOIN claimius.user_claim uc ON uc.claim_id = (g ->> 'claim_id')::UUID
            AND uc.user_id = p_user_id
            AND uc.app_id = p_app_id
            AND uc.sa_deleted_at IS NULL
            AND (uc.starts_at IS NULL OR uc.starts_at <= now())
            AND (uc.ends_at IS NULL OR uc.ends_at > now())
                 JOIN claimius.claim c ON c.id = uc.claim_id AND c.sa_deleted_at IS NULL
        WHERE uo.user_id = p_user_id
          AND uo.app_id = p_app_id
          AND uo.object_id = p_object_id
          AND uo.object_type = p_object_type
        ORDER BY claimius._popcount(c.sa_access) DESC;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_claims(UUID, UUID, UUID, TEXT) IS 'All claims the user holds against one object.';

-- ----------------------------------------------------------------------------
-- get_access (overload: scope key form)
-- Strongest active object-less binding whose scope contains p_scope_key and
-- whose mask covers p_required_access. Returns user_claim_id, claim_id,
-- sa_access, scope.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.get_access(
    p_user_id          UUID,
    p_app_id           UUID,
    p_scope_key        TEXT,
    p_required_access  INTEGER DEFAULT 0
) RETURNS TABLE (
                    user_claim_id   UUID,
                    claim_id        UUID,
                    sa_access       INTEGER,
                    scope           JSONB
                ) AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
        SELECT uc.id,
               c.id,
               (c.sa_access | co.sa_access) & 15,
               co.scope
        FROM claimius.user_claim uc
                 JOIN claimius.claim c ON c.id = uc.claim_id
                 JOIN claimius.claim_object co
                      ON co.claim_id = uc.claim_id
                     AND co.app_id = uc.app_id
        WHERE uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.sa_deleted_at IS NULL
          AND c.sa_deleted_at IS NULL
          AND co.sa_deleted_at IS NULL
          AND (uc.starts_at IS NULL OR uc.starts_at <= now())
          AND (uc.ends_at  IS NULL OR uc.ends_at  >  now())
          AND co.object_id IS NULL
          AND co.scope ? p_scope_key
          AND ((c.sa_access | co.sa_access) & 16) = 0
          AND (((c.sa_access | co.sa_access) & 15) & p_required_access) = p_required_access
        ORDER BY claimius._popcount(((c.sa_access | co.sa_access) & 15)) DESC
        LIMIT 1;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_access(UUID, UUID, TEXT, INTEGER) IS 'Strongest active object-less binding whose scope contains p_scope_key and whose mask covers p_required_access.';

-- ----------------------------------------------------------------------------
-- get_audit
-- Returns audit rows for organizations the user can see.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS claimius.get_audit(UUID, UUID, INTEGER, INTEGER, INTEGER);

CREATE OR REPLACE FUNCTION claimius.get_audit(
    p_user_id          UUID,
    p_app_id           UUID,
    p_required_access  INTEGER DEFAULT 0,
    p_limit            INTEGER DEFAULT 100,
    p_offset           INTEGER DEFAULT 0
) RETURNS SETOF claimius.audit AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
        SELECT a.*
        FROM claimius.audit a
        WHERE a.app_id = p_app_id
          AND a.sa_owner_id IN (
            SELECT g.object_id FROM claimius.get_objects(p_user_id, p_app_id, 'claimius.organization', p_required_access) g
        )
        ORDER BY a.sa_created_at DESC
        LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_audit(p_user_id uuid, p_app_id uuid, p_required_access integer, p_limit integer, p_offset integer) IS 'Audit rows for organizations the user can see.';

-- ----------------------------------------------------------------------------
-- get_secrets
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS claimius.get_secrets(UUID, UUID, INTEGER);

CREATE OR REPLACE FUNCTION claimius.get_secrets(
    p_user_id          UUID,
    p_app_id           UUID,
    p_required_access  INTEGER DEFAULT 0
) RETURNS SETOF claimius.samna_secret AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
        SELECT s.*
        FROM claimius.samna_secret s
        WHERE s.app_id = p_app_id
          AND s.sa_deleted_at IS NULL
          AND s.id IN (
            SELECT g.object_id FROM claimius.get_objects(p_user_id, p_app_id, 'claimius.samna_secret', p_required_access) g
        );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_secrets(p_user_id uuid, p_app_id uuid, p_required_access integer) IS 'Secrets whose effective mask covers p_required_access.';

-- Drop any stale earlier signatures of the graph functions before redefining.
-- The previous version of these functions had different argument lists; if a
-- migration re-runs against a database that still has the old signature, the
-- bare CREATE OR REPLACE below would create a second overloaded version
-- instead of replacing, and downstream COMMENT/REVOKE statements would not
-- resolve unambiguously.
DROP FUNCTION IF EXISTS claimius.get_owner_graph(UUID, UUID, INTEGER);
DROP FUNCTION IF EXISTS claimius.get_claim_graph(UUID, UUID, INTEGER);

-- ----------------------------------------------------------------------------
-- get_owner_graph
-- Returns the ownership graph the user can see as a flat node list. Covers
-- organizations, locations, AND every registered application table that has
-- sa_owner_id and/or sa_location_id. Each row carries a single canonical
-- parent_id (priority: sa_parent_id, then sa_location_id, then sa_owner_id);
-- secondary relationships ride in the data jsonb so the frontend can draw
-- additional edges if it wants.
--
-- Args:
--   p_user_id   - reading user
--   p_app_id    - app scope
--   p_start_id  - optional organization id; when set, restricts the result to
--                 the subtree rooted at that org (and the org itself). NULL
--                 means every root the user can see.
--   p_depth     - how many levels of descent below the start org. 0 means
--                 unlimited. The org at p_start_id (or each accessible root
--                 when start is NULL) is depth 0; its direct children are
--                 depth 1; and so on.
--   p_required_access - access bit filter passed through to get_objects.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.get_owner_graph(
    p_user_id          UUID,
    p_app_id           UUID,
    p_start_id         UUID DEFAULT NULL,
    p_depth            INTEGER DEFAULT 0,
    p_required_access  INTEGER DEFAULT 0
) RETURNS TABLE(object_id UUID, object_type TEXT, label TEXT, parent_id UUID, data JSONB) AS $$
DECLARE
    v_root_ids      UUID[];
    v_table         RECORD;
    v_sql           TEXT;
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    -- Resolve the set of root organizations to walk from.
    -- When p_start_id is null we use every root org the user can see.
    -- When p_start_id is provided it must be an org the user can see; if not,
    -- we return empty silently (no rows yielded, no error).
    IF p_start_id IS NULL THEN
        SELECT array_agg(o.id) INTO v_root_ids
        FROM claimius.organization o
        WHERE o.app_id = p_app_id
          AND o.sa_deleted_at IS NULL
          AND o.sa_owner_id = o.id  -- root: self referential
          AND o.id IN (
            SELECT g.object_id FROM claimius.get_objects(p_user_id, p_app_id, 'claimius.organization', p_required_access) g
        );
    ELSE
        SELECT ARRAY[o.id] INTO v_root_ids
        FROM claimius.organization o
        WHERE o.app_id = p_app_id
          AND o.id = p_start_id
          AND o.sa_deleted_at IS NULL
          AND o.id IN (
            SELECT g.object_id FROM claimius.get_objects(p_user_id, p_app_id, 'claimius.organization', p_required_access) g
        );
    END IF;

    IF v_root_ids IS NULL OR array_length(v_root_ids, 1) IS NULL THEN
        RETURN;
    END IF;

    -- Organizations: walk each root's ownership tree, depth limited.
    -- Recursive CTE bound to the access filter and the depth limit.
    RETURN QUERY
        WITH RECURSIVE org_walk AS (
            SELECT o.id, o.name::TEXT AS name, o.description, o.type::TEXT AS type, o.sa_level,
                   o.sa_owner_id, 0 AS lvl
            FROM claimius.organization o
            WHERE o.app_id = p_app_id
              AND o.sa_deleted_at IS NULL
              AND o.id = ANY(v_root_ids)
            UNION ALL
            SELECT c.id, c.name::TEXT, c.description, c.type::TEXT, c.sa_level,
                   c.sa_owner_id, w.lvl + 1
            FROM claimius.organization c
                     JOIN org_walk w ON c.sa_owner_id = w.id
            WHERE c.app_id = p_app_id
              AND c.sa_deleted_at IS NULL
              AND c.id <> c.sa_owner_id  -- don't re-walk the root
              AND (p_depth = 0 OR w.lvl + 1 <= p_depth)
        )
        SELECT w.id ,
               'claimius.organization'::TEXT ,
               w.name::TEXT ,
               CASE WHEN w.id = w.sa_owner_id OR (w.lvl = 0 AND p_start_id IS NULL) THEN NULL
                    ELSE w.sa_owner_id
                   END ,
               jsonb_build_object(
                       'access', uo.sa_access, 'scope', uo.scope,
                       'level', w.sa_level,
                       'description', w.description,
                       'type', w.type,
                       'owner_id', w.sa_owner_id
               )
        FROM org_walk w
                 LEFT JOIN claimius.user_object uo
                           ON uo.object_id = w.id
                               AND uo.object_type = 'claimius.organization'
                               AND uo.user_id = p_user_id
                               AND uo.app_id = p_app_id
        WHERE w.id IN (
            SELECT g.object_id FROM claimius.get_objects(p_user_id, p_app_id, 'claimius.organization', p_required_access) g
        );

    -- For every other registered table that has sa_owner_id or sa_location_id,
    -- emit rows whose ownership chain lands inside the org subtree we walked.
    -- The walked org subtree is captured as the same recursive CTE above,
    -- materialized once into a temp set used by every per-table query.
    CREATE TEMP TABLE IF NOT EXISTS _owner_graph_orgs (org_id UUID PRIMARY KEY) ON COMMIT DROP;
    DELETE FROM _owner_graph_orgs;

    INSERT INTO _owner_graph_orgs(org_id)
    WITH RECURSIVE org_walk AS (
        SELECT o.id, 0 AS lvl
        FROM claimius.organization o
        WHERE o.app_id = p_app_id
          AND o.sa_deleted_at IS NULL
          AND o.id = ANY(v_root_ids)
        UNION ALL
        SELECT c.id, w.lvl + 1
        FROM claimius.organization c
                 JOIN org_walk w ON c.sa_owner_id = w.id
        WHERE c.app_id = p_app_id
          AND c.sa_deleted_at IS NULL
          AND c.id <> c.sa_owner_id
          AND (p_depth = 0 OR w.lvl + 1 <= p_depth)
    )
    SELECT id FROM org_walk;

    -- Locations: handled explicitly so we keep longitude/latitude in data.
    -- Filtered to locations whose owning org sits in the walked org set.
    RETURN QUERY
        SELECT l.id ,
               'claimius.location'::TEXT ,
               l.name::TEXT ,
               CASE WHEN l.sa_parent_id = l.id THEN l.sa_owner_id ELSE l.sa_parent_id END ,
               jsonb_build_object(
                       'access', uo.sa_access, 'scope', uo.scope,
                       'level', l.sa_level,
                       'description', l.description,
                       'type', l.type,
                       'owner_id', l.sa_owner_id,
                       'longitude', l.longitude,
                       'latitude', l.latitude
               )
        FROM claimius.location l
                 LEFT JOIN claimius.user_object uo
                           ON uo.object_id = l.id
                               AND uo.object_type = 'claimius.location'
                               AND uo.user_id = p_user_id
                               AND uo.app_id = p_app_id
        WHERE l.app_id = p_app_id
          AND l.sa_deleted_at IS NULL
          AND l.sa_owner_id IN (SELECT org_id FROM _owner_graph_orgs)
          AND l.id IN (
            SELECT g.object_id FROM claimius.get_objects(p_user_id, p_app_id, 'claimius.location', p_required_access) g
        );

    -- Iterate every registered table that participates in ownership/location
    -- and emit rows whose sa_owner_id resolves into the walked org set.
    -- Locations and other tables share the same general shape; we keep
    -- locations separate only because their parent_id falls back to
    -- sa_owner_id when sa_parent_id is self referential.
    FOR v_table IN
        SELECT claimius.table_info.object_type,
               claimius.table_info.has_sa_owner_id,
               claimius.table_info.has_sa_location_id,
               claimius.table_info.has_sa_parent_id,
               claimius.table_info.has_sa_deleted_at
        FROM claimius.table_info
        WHERE (claimius.table_info.has_sa_owner_id OR claimius.table_info.has_sa_location_id)
          AND claimius.table_info.object_type <> 'claimius.organization'
          AND claimius.table_info.object_type <> 'claimius.location'
          AND claimius.table_info.object_type <> 'claimius.samna_user'
        LOOP
            v_sql := format($f$
            SELECT t.id::UUID,
                   %L::TEXT,
                   coalesce(uo.sa_name, t.id::TEXT)::TEXT,
                   CASE
                       %s
                       %s
                       %s
                       ELSE NULL::UUID
                   END,
                   jsonb_build_object(
                       'access', uo.sa_access, 'scope', uo.scope,
                       'level', NULL::INTEGER,
                       'description', uo.sa_description,
                       'owner_id', uo.sa_owner_id,
                       'location_id', uo.sa_location_id
                   )
            FROM %I.%I t
            JOIN claimius.user_object uo
              ON uo.object_id = t.id
             AND uo.object_type = %L
             AND uo.user_id = $1
             AND uo.app_id = $2
             AND (uo.sa_access & $3) = $3
            WHERE %s
              AND (
                  %s
                  %s
              )
        $f$,
                            v_table.object_type,
                -- parent_id CASE arms in priority order: parent, location, owner
                            CASE WHEN v_table.has_sa_parent_id THEN 'WHEN t.sa_parent_id IS NOT NULL AND t.sa_parent_id <> t.id THEN t.sa_parent_id' ELSE '' END,
                            CASE WHEN v_table.has_sa_location_id THEN 'WHEN t.sa_location_id IS NOT NULL THEN t.sa_location_id' ELSE '' END,
                            CASE WHEN v_table.has_sa_owner_id THEN 'WHEN t.sa_owner_id IS NOT NULL AND t.sa_owner_id <> t.id THEN t.sa_owner_id' ELSE '' END,
                            split_part(v_table.object_type, '.', 1),
                            split_part(v_table.object_type, '.', 2),
                            v_table.object_type,
                -- soft-delete predicate (table dependent)
                            CASE WHEN v_table.has_sa_deleted_at THEN 't.sa_deleted_at IS NULL' ELSE 'TRUE' END,
                -- ancestry: must root in the walked org set (via owner or via owner of location)
                            CASE WHEN v_table.has_sa_owner_id THEN 't.sa_owner_id IN (SELECT org_id FROM _owner_graph_orgs)' ELSE 'FALSE' END,
                            CASE WHEN v_table.has_sa_location_id THEN ' OR EXISTS (SELECT 1 FROM claimius.location loc WHERE loc.id = t.sa_location_id AND loc.sa_owner_id IN (SELECT org_id FROM _owner_graph_orgs))' ELSE '' END
                     );

            RETURN QUERY EXECUTE v_sql USING p_user_id, p_app_id, p_required_access;
        END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_owner_graph(UUID, UUID, UUID, INTEGER, INTEGER) IS 'Ownership graph (orgs, locations, registered tables with sa_owner_id or sa_location_id) for the user. Optional start org and depth limit.';

-- ----------------------------------------------------------------------------
-- get_claim_graph
-- Returns the access graph: the requesting user, every other user this user
-- can see, every claim the user holds (or just the start claim), the
-- user_claim grants, the claim_object connector nodes that bind claims to
-- objects, and the actual objects reachable from those bindings (every
-- registered object_type, served via the user_object materialization).
--
-- Topology:
--   user (parent_id = NULL)
--     |- user_claim   (parent_id = user.id)
--     |     '- (the user_claim points at a claim by claim_id in data)
--     '- (other users seen via user_users; parent_id = the requesting user.id)
--   claim (parent_id = NULL)
--     '- claim_object   (parent_id = claim.id)
--           '- object   (parent_id = claim_object.id)
--
-- Args:
--   p_user_id   - reading user
--   p_app_id    - app scope
--   p_start_id  - optional claim id; when set, restricts the walk to that
--                 single claim (must be one the user holds, otherwise empty).
--                 NULL means every claim the user holds.
--   p_depth     - cascade depth from each claim_object binding. 0 = unlimited
--                 (all objects in user_object reachable through the binding).
--                 1 = directly bound objects only, no cascade descendants.
--                 N = directly bound plus N-1 cascade hops.
--   p_required_access - bit filter; claims and reachable objects whose
--                       effective mask does not cover these bits are excluded.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.get_claim_graph(
    p_user_id          UUID,
    p_app_id           UUID,
    p_start_id         UUID DEFAULT NULL,
    p_depth            INTEGER DEFAULT 0,
    p_required_access  INTEGER DEFAULT 0
) RETURNS TABLE(object_id UUID, object_type TEXT, label TEXT, parent_id UUID, data JSONB) AS $$
DECLARE
    v_claim_ids     UUID[];
    v_user_row_id   UUID;
    v_cacheable     BOOLEAN;
    v_graph         JSONB;
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    v_cacheable := (p_start_id IS NULL AND p_depth = 0 AND p_required_access = 0);

    IF v_cacheable THEN
        SELECT c.graph INTO v_graph
        FROM claimius.claim_graph_cache c
        WHERE c.app_id = p_app_id AND c.user_id = p_user_id;

        IF v_graph IS NOT NULL THEN
            RETURN QUERY
                SELECT (e->>'object_id')::UUID,
                       e->>'object_type',
                       e->>'label',
                       NULLIF(e->>'parent_id', '')::UUID,
                       e->'data'
                FROM jsonb_array_elements(v_graph) AS e;
            RETURN;
        END IF;
    END IF;

    IF p_start_id IS NULL THEN
        SELECT array_agg(uc.claim_id) INTO v_claim_ids
        FROM claimius.user_claim uc
                 JOIN claimius.claim c ON c.id = uc.claim_id
        WHERE uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.sa_deleted_at IS NULL
          AND c.sa_deleted_at IS NULL
          AND (c.sa_access & p_required_access) = p_required_access;
    ELSE
        SELECT array_agg(uc.claim_id) INTO v_claim_ids
        FROM claimius.user_claim uc
                 JOIN claimius.claim c ON c.id = uc.claim_id
        WHERE uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.claim_id = p_start_id
          AND uc.sa_deleted_at IS NULL
          AND c.sa_deleted_at IS NULL
          AND (c.sa_access & p_required_access) = p_required_access;
    END IF;

    IF v_claim_ids IS NULL OR array_length(v_claim_ids, 1) IS NULL THEN
        RETURN;
    END IF;

    SELECT u.id INTO v_user_row_id
    FROM claimius.samna_user u
    WHERE u.user_id = p_user_id AND u.app_id = p_app_id
      AND u.sa_deleted_at IS NULL
    LIMIT 1;

    WITH grant_anchors AS (
        SELECT uo.object_id          AS uo_object_id,
               uo.object_type        AS uo_object_type,
               uo.sa_access          AS uo_access,
               uo.scope              AS uo_scope,
               uo.sa_name            AS uo_name,
               uo.sa_description     AS uo_description,
               uo.sa_owner_id        AS uo_owner_id,
               uo.sa_location_id     AS uo_location_id,
               (e->>'claim_id')::UUID  AS claim_id,
               e->>'tree_type'         AS tree_type,
               CASE WHEN e->>'tree_type' = 'direct'
                    THEN uo.object_type
                    ELSE e -> 'cascaded_from' ->> 'type' END  AS anchor_type,
               CASE WHEN e->>'tree_type' = 'direct'
                    THEN uo.object_id
                    ELSE (e -> 'cascaded_from' ->> 'id')::UUID END  AS anchor_id
        FROM claimius.user_object uo
                 CROSS JOIN LATERAL jsonb_array_elements(uo.grants) e
        WHERE uo.user_id = p_user_id
          AND uo.app_id = p_app_id
          AND (uo.sa_access & p_required_access) = p_required_access
          AND (e->>'claim_id')::UUID = ANY(v_claim_ids)
          AND (p_depth = 0 OR e->>'tree_type' = 'direct')
    ),
    self_node AS (
        SELECT u.id                                                                     AS object_id,
               'claimius.samna_user'::TEXT                                              AS object_type,
               coalesce(u.first_name || ' ' || u.last_name, u.email, u.user_id::TEXT)::TEXT  AS label,
               NULL::UUID                                                               AS parent_id,
               jsonb_build_object(
                   'access', NULL::INTEGER,
                   'scope', NULL::JSONB,
                   'level', NULL::INTEGER,
                   'user_id', u.user_id,
                   'email', u.email,
                   'external_id', u.external_id,
                   'status', u.status
               )                                                                        AS data
        FROM claimius.samna_user u
        WHERE u.id = v_user_row_id
    ),
    other_users_node AS (
        SELECT u.id                                                                     AS object_id,
               'claimius.samna_user'::TEXT                                              AS object_type,
               coalesce(u.first_name || ' ' || u.last_name, u.email, u.user_id::TEXT)::TEXT  AS label,
               v_user_row_id                                                            AS parent_id,
               jsonb_build_object(
                   'access', uo.sa_access, 'scope', uo.scope,
                   'level', NULL::INTEGER,
                   'user_id', u.user_id,
                   'email', u.email,
                   'external_id', u.external_id,
                   'status', u.status
               )                                                                        AS data
        FROM claimius.samna_user u
                 JOIN claimius.user_users uu
                      ON uu.viewer_id = p_user_id
                          AND uu.app_id = p_app_id
                          AND uu.target_user_id = u.user_id
                 LEFT JOIN claimius.user_object uo
                      ON uo.object_id = u.id
                          AND uo.object_type = 'claimius.samna_user'
                          AND uo.user_id = p_user_id
                          AND uo.app_id = p_app_id
        WHERE u.app_id = p_app_id
          AND u.sa_deleted_at IS NULL
          AND u.id <> v_user_row_id
    ),
    user_claim_node AS (
        SELECT uc.id                AS object_id,
               'claimius.user_claim'::TEXT  AS object_type,
               c.name::TEXT         AS label,
               v_user_row_id        AS parent_id,
               jsonb_build_object(
                   'access', NULL::INTEGER,
                   'scope', NULL::JSONB,
                   'level', NULL::INTEGER,
                   'claim_id', uc.claim_id,
                   'starts_at', uc.starts_at,
                   'ends_at', uc.ends_at,
                   'reason', uc.reason
               )                    AS data
        FROM claimius.user_claim uc
                 JOIN claimius.claim c ON c.id = uc.claim_id
        WHERE uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.sa_deleted_at IS NULL
          AND uc.claim_id = ANY(v_claim_ids)
    ),
    claim_node AS (
        SELECT c.id                 AS object_id,
               'claimius.claim'::TEXT  AS object_type,
               c.name::TEXT         AS label,
               NULL::UUID           AS parent_id,
               jsonb_build_object(
                   'access', c.sa_access,
                   'scope', NULL::JSONB,
                   'level', NULL::INTEGER,
                   'description', c.description,
                   'inherits', c.inherits,
                   'type', c.type
               )                    AS data
        FROM claimius.claim c
        WHERE c.app_id = p_app_id
          AND c.sa_deleted_at IS NULL
          AND c.id = ANY(v_claim_ids)
    ),
    claim_object_node AS (
        SELECT co.id                AS object_id,
               'claimius.claim_object'::TEXT  AS object_type,
               coalesce(uo.sa_name, co.object_id::TEXT, '')::TEXT  AS label,
               co.claim_id          AS parent_id,
               jsonb_build_object(
                   'access', co.sa_access,
                   'scope', co.scope,
                   'level', NULL::INTEGER,
                   'target_object_id', co.object_id,
                   'target_object_type', co.object_type,
                   'inherits', co.inherits
               )                    AS data
        FROM claimius.claim_object co
                 LEFT JOIN claimius.user_object uo
                      ON uo.object_id = co.object_id
                          AND uo.object_type = co.object_type
                          AND uo.user_id = p_user_id
                          AND uo.app_id = p_app_id
        WHERE co.app_id = p_app_id
          AND co.sa_deleted_at IS NULL
          AND co.claim_id = ANY(v_claim_ids)
    ),
    object_node AS (
        SELECT ga.uo_object_id      AS object_id,
               ga.uo_object_type    AS object_type,
               coalesce(ga.uo_name, ga.uo_object_id::TEXT)::TEXT  AS label,
               co.id                AS parent_id,
               jsonb_build_object(
                   'access', ga.uo_access,
                   'scope', ga.uo_scope,
                   'level', NULL::INTEGER,
                   'description', ga.uo_description,
                   'owner_id', ga.uo_owner_id,
                   'location_id', ga.uo_location_id,
                   'tree_type', ga.tree_type
               )                    AS data
        FROM grant_anchors ga
                 JOIN claimius.claim_object co
                      ON co.app_id = p_app_id
                          AND co.claim_id = ga.claim_id
                          AND co.object_type = ga.anchor_type
                          AND co.object_id = ga.anchor_id
                          AND co.sa_deleted_at IS NULL
    ),
    all_nodes AS (
        SELECT * FROM self_node
        UNION ALL
        SELECT * FROM other_users_node
        UNION ALL
        SELECT * FROM user_claim_node
        UNION ALL
        SELECT * FROM claim_node
        UNION ALL
        SELECT * FROM claim_object_node
        UNION ALL
        SELECT * FROM object_node
    )
    SELECT jsonb_agg(jsonb_build_object(
                'object_id', n.object_id,
                'object_type', n.object_type,
                'label', n.label,
                'parent_id', n.parent_id,
                'data', n.data
           )) INTO v_graph
    FROM all_nodes n;

    IF v_graph IS NULL THEN
        v_graph := '[]'::JSONB;
    END IF;

    IF v_cacheable THEN
        INSERT INTO claimius.claim_graph_cache (app_id, user_id, graph, sa_updated_at)
        VALUES (p_app_id, p_user_id, v_graph, now())
        ON CONFLICT (app_id, user_id) DO UPDATE
            SET graph = EXCLUDED.graph,
                sa_updated_at = EXCLUDED.sa_updated_at;
    END IF;

    RETURN QUERY
        SELECT (e->>'object_id')::UUID,
               e->>'object_type',
               e->>'label',
               NULLIF(e->>'parent_id', '')::UUID,
               e->'data'
        FROM jsonb_array_elements(v_graph) AS e;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_claim_graph(UUID, UUID, UUID, INTEGER, INTEGER) IS 'Access graph: user, other users seen, claims, user_claims, claim_object bindings, reachable objects. Optional start claim and depth limit. Default shape served from claimius.claim_graph_cache.';

CREATE OR REPLACE FUNCTION claimius._invalidate_claim_graph_cache()
    RETURNS TRIGGER AS $$
DECLARE
    v_app_id    UUID;
    v_user_id   UUID;
BEGIN
    IF TG_TABLE_NAME = 'user_object' THEN
        v_app_id  := COALESCE(NEW.app_id, OLD.app_id);
        v_user_id := COALESCE(NEW.user_id, OLD.user_id);
        DELETE FROM claimius.claim_graph_cache
        WHERE app_id = v_app_id AND user_id = v_user_id;
    ELSIF TG_TABLE_NAME = 'user_users' THEN
        v_app_id  := COALESCE(NEW.app_id, OLD.app_id);
        v_user_id := COALESCE(NEW.viewer_id, OLD.viewer_id);
        DELETE FROM claimius.claim_graph_cache
        WHERE app_id = v_app_id AND user_id = v_user_id;
    ELSIF TG_TABLE_NAME = 'samna_user' THEN
        v_app_id  := COALESCE(NEW.app_id, OLD.app_id);
        v_user_id := COALESCE(NEW.user_id, OLD.user_id);
        DELETE FROM claimius.claim_graph_cache
        WHERE app_id = v_app_id AND user_id = v_user_id;
    ELSIF TG_TABLE_NAME = 'claim' OR TG_TABLE_NAME = 'claim_object' THEN
        v_app_id := COALESCE(NEW.app_id, OLD.app_id);
        DELETE FROM claimius.claim_graph_cache
        WHERE app_id = v_app_id;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._invalidate_claim_graph_cache() IS 'Trigger function. Drops claim_graph_cache rows affected by writes to user_object, user_users, samna_user, claim, claim_object.';

-- ----------------------------------------------------------------------------
-- search
-- Full text search over accessible objects (anything with a user_object row),
-- gated by access. Matches against the precomputed search_vector column.
-- The search_vector is fed by sa_name, sa_description, sa_link via the
-- denormalization in V2.2.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS claimius.search_objects(UUID, UUID, TEXT, TEXT[], INTEGER, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS claimius.search(UUID, UUID, TEXT, TEXT[], INTEGER, INTEGER, INTEGER);

CREATE OR REPLACE FUNCTION claimius.search(
    p_user_id          UUID,
    p_app_id           UUID,
    p_query            TEXT,
    p_object_types     TEXT[] DEFAULT NULL,
    p_required_access  INTEGER DEFAULT 0,
    p_limit            INTEGER DEFAULT 20,
    p_offset           INTEGER DEFAULT 0
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
          AND (best.uc_id IS NOT NULL OR claimius.user_object.direct_grant)
        ORDER BY ts_rank(claimius.user_object.search_vector, v_tsquery) DESC
        LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.search(UUID, UUID, TEXT, TEXT[], INTEGER, INTEGER, INTEGER) IS 'Full text search over accessible objects whose mask covers p_required_access. user_claim_id is the actor token from the strongest surviving claim grant per object.';

-- ============================================================================
-- Write functions: claim management
-- ============================================================================

-- create_claim
DROP FUNCTION IF EXISTS claimius.create_claim(UUID, TEXT, TEXT, INTEGER, UUID, UUID, UUID, BOOLEAN, BOOLEAN, claimius.claim_type);

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
    v_row claimius.claim;
BEGIN
    INSERT INTO claimius.claim (
        app_id, name, description, sa_access, inherits, type,
        sa_owner_id, sa_root_id, sa_created_by
    ) VALUES (
                 p_app_id, p_name, p_description, p_sa_access, p_inherits, p_type,
                 p_sa_owner_id, p_sa_root_id, p_sa_created_by
             ) RETURNING * INTO v_row;
    RETURN jsonb_build_object('claim', to_jsonb(v_row));
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.create_claim(p_app_id uuid, p_name text, p_description text, p_sa_access integer, p_sa_owner_id uuid, p_sa_root_id uuid, p_sa_created_by uuid, p_inherits boolean, p_type claimius.claim_type) IS 'Creates a new claim. p_sa_access is a bitwise mask: 0x01 owner, 0x02 write, 0x04 read, 0x08 execute, 0x10 deny.';

-- update_claim
DROP FUNCTION IF EXISTS claimius.update_claim(UUID, TEXT, TEXT, INTEGER, BOOLEAN, BOOLEAN);

CREATE OR REPLACE FUNCTION claimius.update_claim(
    p_claim_id          UUID,
    p_name              TEXT DEFAULT NULL,
    p_description       TEXT DEFAULT NULL,
    p_sa_access         INTEGER DEFAULT NULL,
    p_inherits          BOOLEAN DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_row claimius.claim;
BEGIN
    UPDATE claimius.claim SET
                              name        = coalesce(p_name, name),
                              description = coalesce(p_description, description),
                              sa_access   = coalesce(p_sa_access, sa_access),
                              inherits    = coalesce(p_inherits, inherits)
    WHERE id = p_claim_id
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('claim', to_jsonb(v_row));
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.update_claim(p_claim_id uuid, p_name text, p_description text, p_sa_access integer, p_inherits boolean) IS 'Patches selected fields on a claim.';

-- remove_claim
CREATE OR REPLACE FUNCTION claimius.remove_claim(
    p_claim_id      UUID,
    p_deleted_by    UUID
) RETURNS BOOLEAN AS $$
BEGIN
    UPDATE claimius.claim SET sa_deleted_at = now() WHERE id = p_claim_id AND sa_deleted_at IS NULL;
    UPDATE claimius.user_claim SET sa_deleted_at = now() WHERE claim_id = p_claim_id AND sa_deleted_at IS NULL;
    UPDATE claimius.claim_object SET sa_deleted_at = now() WHERE claim_id = p_claim_id AND sa_deleted_at IS NULL;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.remove_claim(p_claim_id uuid, p_deleted_by uuid) IS 'Soft deletes a claim and its user_claim and claim_object rows.';

-- assign_claim_user
CREATE OR REPLACE FUNCTION claimius.assign_claim_user(
    p_app_id        UUID,
    p_claim_id      UUID,
    p_user_id       UUID,
    p_sa_owner_id   UUID,
    p_sa_created_by UUID,
    p_reason        TEXT DEFAULT NULL,
    p_starts_at     TIMESTAMPTZ DEFAULT NULL,
    p_ends_at       TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_row claimius.user_claim;
BEGIN
    INSERT INTO claimius.user_claim (
        app_id, claim_id, user_id, reason, starts_at, ends_at,
        sa_owner_id, sa_created_by
    ) VALUES (
                 p_app_id, p_claim_id, p_user_id, p_reason, p_starts_at, p_ends_at,
                 p_sa_owner_id, p_sa_created_by
             ) RETURNING * INTO v_row;
    RETURN jsonb_build_object('user_claim', to_jsonb(v_row));
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.assign_claim_user(p_app_id uuid, p_claim_id uuid, p_user_id uuid, p_sa_owner_id uuid, p_sa_created_by uuid, p_reason text, p_starts_at timestamp with time zone, p_ends_at timestamp with time zone) IS 'Grants a claim to a user in an app.';

-- update_claim_user
CREATE OR REPLACE FUNCTION claimius.update_claim_user(
    p_user_claim_id UUID,
    p_reason        TEXT DEFAULT NULL,
    p_starts_at     TIMESTAMPTZ DEFAULT NULL,
    p_ends_at       TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_row claimius.user_claim;
BEGIN
    UPDATE claimius.user_claim SET
                                   reason = coalesce(p_reason, reason),
                                   starts_at = coalesce(p_starts_at, starts_at),
                                   ends_at = coalesce(p_ends_at, ends_at)
    WHERE id = p_user_claim_id
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('user_claim', to_jsonb(v_row));
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.update_claim_user(p_user_claim_id uuid, p_reason text, p_starts_at timestamp with time zone, p_ends_at timestamp with time zone) IS 'Patches selected fields on a user_claim.';

-- remove_user_claim
CREATE OR REPLACE FUNCTION claimius.remove_user_claim(
    p_user_claim_id UUID,
    p_deleted_by    UUID
) RETURNS BOOLEAN AS $$
BEGIN
    UPDATE claimius.user_claim SET sa_deleted_at = now()
    WHERE id = p_user_claim_id AND sa_deleted_at IS NULL;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.remove_user_claim(p_user_claim_id uuid, p_deleted_by uuid) IS 'Soft deletes a user_claim row.';

-- assign_claim_object
DROP FUNCTION IF EXISTS claimius.assign_claim_object(UUID, UUID, UUID, TEXT, UUID, UUID, UUID, INTEGER, BOOLEAN, TEXT, UUID, TEXT);

CREATE OR REPLACE FUNCTION claimius.assign_claim_object(
    p_app_id        UUID,
    p_claim_id      UUID,
    p_sa_owner_id   UUID,
    p_sa_root_id    UUID,
    p_sa_created_by UUID,
    p_object_id     UUID DEFAULT NULL,
    p_object_type   TEXT DEFAULT NULL,
    p_sa_access     INTEGER DEFAULT NULL,
    p_inherits      BOOLEAN DEFAULT TRUE,
    p_reason        TEXT DEFAULT NULL,
    p_ref_id        UUID DEFAULT NULL,
    p_scope         JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_row claimius.claim_object;
BEGIN
    INSERT INTO claimius.claim_object (
        app_id, claim_id, object_id, object_type, reason, scope,
        sa_access, inherits, ref_id, sa_owner_id, sa_root_id, sa_created_by
    ) VALUES (
                 p_app_id, p_claim_id, p_object_id, p_object_type, p_reason, p_scope,
                 p_sa_access, p_inherits, p_ref_id, p_sa_owner_id, p_sa_root_id, p_sa_created_by
             ) RETURNING * INTO v_row;
    RETURN jsonb_build_object('claim_object', to_jsonb(v_row));
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.assign_claim_object(p_app_id uuid, p_claim_id uuid, p_sa_owner_id uuid, p_sa_root_id uuid, p_sa_created_by uuid, p_object_id uuid, p_object_type text, p_sa_access integer, p_inherits boolean, p_reason text, p_ref_id uuid, p_scope jsonb) IS 'Binds a claim. With (object_type, object_id) p_scope keys are field names; without them p_scope keys are custom. p_sa_access is a bitwise mask.';

-- update_claim_object
DROP FUNCTION IF EXISTS claimius.update_claim_object(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE FUNCTION claimius.update_claim_object(
    p_claim_object_id UUID,
    p_reason        TEXT DEFAULT NULL,
    p_inherits      BOOLEAN DEFAULT NULL,
    p_sa_access     INTEGER DEFAULT NULL,
    p_scope         JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_row claimius.claim_object;
BEGIN
    UPDATE claimius.claim_object SET
                                     reason    = coalesce(p_reason, reason),
                                     inherits  = coalesce(p_inherits, inherits),
                                     sa_access = coalesce(p_sa_access, sa_access),
                                     scope     = coalesce(p_scope, scope)
    WHERE id = p_claim_object_id
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('claim_object', to_jsonb(v_row));
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.update_claim_object(p_claim_object_id uuid, p_reason text, p_inherits boolean, p_sa_access integer, p_scope jsonb) IS 'Patches selected fields on a claim_object.';

-- remove_claim_object
CREATE OR REPLACE FUNCTION claimius.remove_claim_object(
    p_claim_object_id UUID,
    p_deleted_by      UUID
) RETURNS BOOLEAN AS $$
BEGIN
    UPDATE claimius.claim_object SET sa_deleted_at = now()
    WHERE id = p_claim_object_id AND sa_deleted_at IS NULL;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.remove_claim_object(p_claim_object_id uuid, p_deleted_by uuid) IS 'Soft deletes a claim_object row.';

-- ============================================================================
-- merge_user
-- Reassigns all data from a source user to a target user. Operates by
-- user_id (not row PK) and unifies across apps. Hard deletes the source
-- samna_user row(s) and migrates user_claim, user_relation, user_field,
-- user_object, object_users, user_users to the target. External tables
-- registered through init_claimius_tables can opt in by passing themselves
-- in p_external_tables; the function will UPDATE their sa_created_by
-- references where applicable.
-- ============================================================================

CREATE OR REPLACE FUNCTION claimius.merge_user(
    p_target_user_id    UUID,
    p_source_user_id    UUID,
    p_acting_user_claim UUID DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_app_row RECORD;
    v_target_app_user RECORD;
    v_source_app_user RECORD;
BEGIN
    -- Migrate per app
    FOR v_app_row IN
        SELECT DISTINCT app_id FROM claimius.samna_user
        WHERE user_id IN (p_target_user_id, p_source_user_id) AND sa_deleted_at IS NULL
        LOOP
            SELECT * INTO v_target_app_user FROM claimius.samna_user
            WHERE user_id = p_target_user_id AND app_id = v_app_row.app_id AND sa_deleted_at IS NULL;
            SELECT * INTO v_source_app_user FROM claimius.samna_user
            WHERE user_id = p_source_user_id AND app_id = v_app_row.app_id AND sa_deleted_at IS NULL;

            IF v_source_app_user.id IS NULL THEN
                CONTINUE;
            END IF;

            IF v_target_app_user.id IS NULL THEN
                -- Target has no row for this app: rename the source row to target user_id
                UPDATE claimius.samna_user
                SET user_id = p_target_user_id, sa_updated_at = now()
                WHERE id = v_source_app_user.id;
            ELSE
                -- Target already has a row for this app. Merge claims/relations/fields.
                UPDATE claimius.user_claim SET user_id = p_target_user_id
                WHERE user_id = p_source_user_id AND app_id = v_app_row.app_id;
                UPDATE claimius.user_relation SET user_id = p_target_user_id
                WHERE user_id = p_source_user_id AND app_id = v_app_row.app_id;
                UPDATE claimius.user_field SET user_id = p_target_user_id
                WHERE user_id = p_source_user_id AND app_id = v_app_row.app_id;

                -- Propagate the source's profile metadata onto the target row.
                -- Replace name, image, phone, and config unconditionally; fill
                -- email only when the target's email is NULL or empty so an
                -- explicitly set target address is never silently overwritten.
                -- external_id: source value wins when set; source NULL leaves
                -- the target's value intact.
                UPDATE claimius.samna_user
                SET first_name    = v_source_app_user.first_name,
                    last_name     = v_source_app_user.last_name,
                    user_name     = v_source_app_user.user_name,
                    user_image    = v_source_app_user.user_image,
                    phone         = v_source_app_user.phone,
                    config        = v_source_app_user.config,
                    external_id   = coalesce(v_source_app_user.external_id, external_id),
                    email         = CASE
                                        WHEN coalesce(NULLIF(email, ''), NULL) IS NULL
                                            THEN v_source_app_user.email
                                        ELSE email
                        END,
                    sa_updated_at = now()
                WHERE id = v_target_app_user.id;

                -- Hard delete materialized rows for the source; calc functions will
                -- repopulate as transactions touch the target.
                DELETE FROM claimius.user_object
                WHERE user_id = p_source_user_id AND app_id = v_app_row.app_id;
                DELETE FROM claimius.object_users
                WHERE user_id = p_source_user_id AND app_id = v_app_row.app_id;
                DELETE FROM claimius.user_users
                WHERE app_id = v_app_row.app_id
                  AND (viewer_id = p_source_user_id OR target_user_id = p_source_user_id);

                -- Hard delete the source samna_user row
                DELETE FROM claimius.samna_user WHERE id = v_source_app_user.id;
            END IF;

            -- Force recompute of materialized state for the target by touching
            -- every (app, target, object) currently in object_users
            PERFORM claimius._refresh_user_users(v_app_row.app_id, p_target_user_id);

            PERFORM claimius.write_audit(
                    v_app_row.app_id,
                    'merge_user', 'merge', 'claimius.samna_user',
                    p_target_user_id,
                    v_target_app_user.app_id,
                    coalesce(p_acting_user_claim, p_target_user_id),
                    'Merged source ' || p_source_user_id::TEXT || ' into target ' || p_target_user_id::TEXT
                    );
        END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.merge_user(p_target_user_id uuid, p_source_user_id uuid, p_acting_user_claim uuid) IS 'Reassigns all data from source user_id to target user_id across apps.';

-- ============================================================================
-- migrate_root: cross root organization migration. Should be called rarely
-- since calc_hierarchical_access blocks cross root reparenting in the trigger.
-- ============================================================================

CREATE OR REPLACE FUNCTION claimius.migrate_root(
    p_object_type   TEXT,
    p_object_id     UUID,
    p_new_root_id   UUID
) RETURNS VOID AS $$
DECLARE
    v_old_root UUID;
    v_schema TEXT;
    v_table TEXT;
    v_parts TEXT[];
    v_sql TEXT;
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    PERFORM set_config('claimius.replay_mode', 'true', TRUE);

    v_sql := format('SELECT sa_root_id FROM %I.%I WHERE id = $1', v_schema, v_table);
    EXECUTE v_sql INTO v_old_root USING p_object_id;

    -- Walk every descendant in the old tree and rewrite sa_root_id
    EXECUTE format('
        WITH RECURSIVE descendants AS (
            SELECT id FROM %I.%I WHERE id = $1
            UNION ALL
            SELECT t.id FROM %I.%I t JOIN descendants d ON t.sa_parent_id = d.id
            WHERE t.id <> t.sa_parent_id
        )
        UPDATE %I.%I SET sa_root_id = $2 WHERE id IN (SELECT id FROM descendants)
    ', v_schema, v_table, v_schema, v_table, v_schema, v_table)
        USING p_object_id, p_new_root_id;

    PERFORM set_config('claimius.replay_mode', 'false', TRUE);

    -- Rebuild both old and new trees
    IF p_object_type = 'claimius.organization' THEN
        PERFORM claimius.build_ownership_tree(v_old_root);
        PERFORM claimius.build_ownership_tree(p_new_root_id);
    ELSIF p_object_type = 'claimius.location' THEN
        PERFORM claimius.build_location_tree(v_old_root);
        PERFORM claimius.build_location_tree(p_new_root_id);
    ELSE
        PERFORM claimius.build_parenthood_tree(p_object_type, v_old_root);
        PERFORM claimius.build_parenthood_tree(p_object_type, p_new_root_id);
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.migrate_root(p_object_type text, p_object_id uuid, p_new_root_id uuid) IS 'Admin function: cross root migration. Use only when absolutely required.';

-- ============================================================================
-- Init functions
-- ============================================================================

-- init_claimius_tables
-- Registers external app tables. Called by the implementing app's migration.
-- Idempotent: rebuilds registration state from the input list each call.
-- For tables that already have data, seeds materialized state in bulk
-- under replay_mode (triggers do not fire, no events emitted).
CREATE OR REPLACE FUNCTION claimius.init_claimius_tables(
    VARIADIC p_object_types TEXT[]
) RETURNS VOID AS $$
DECLARE
    v_object_type   TEXT;
    v_old_object_type TEXT;
    v_existing      TEXT[];
    v_new           TEXT[];
    v_to_remove     TEXT[];
BEGIN
    -- Snapshot currently registered external tables
    SELECT array_agg(object_type) INTO v_existing
    FROM claimius.table_info WHERE NOT is_internal;

    v_new := p_object_types;

    -- Tables that were registered before but not in the new list: detach
    IF v_existing IS NOT NULL THEN
        SELECT array_agg(o) INTO v_to_remove
        FROM unnest(v_existing) o
        WHERE NOT (o = ANY(v_new));
    END IF;

    IF v_to_remove IS NOT NULL THEN
        FOREACH v_old_object_type IN ARRAY v_to_remove LOOP
                PERFORM claimius._detach_calc_trigger(v_old_object_type);
                PERFORM claimius._detach_self_root_trigger(v_old_object_type);
                DELETE FROM claimius.table_info WHERE object_type = v_old_object_type;
                DELETE FROM claimius.inheritance_info
                 WHERE ancestor_type = v_old_object_type
                    OR descendant_type = v_old_object_type;
                DELETE FROM claimius.user_object WHERE object_type = v_old_object_type;
                DELETE FROM claimius.object_users WHERE object_type = v_old_object_type;
                DELETE FROM claimius.reconcile_queue WHERE object_type = v_old_object_type;
                RAISE NOTICE 'Deregistered table %', v_old_object_type;
            END LOOP;
    END IF;

    -- Register each new (or existing) table
    FOREACH v_object_type IN ARRAY v_new LOOP
            -- normalize to schema.table
            IF position('.' IN v_object_type) = 0 THEN
                v_object_type := 'public.' || v_object_type;
            END IF;
            PERFORM claimius._register_table_info(v_object_type, FALSE);
            PERFORM claimius._attach_calc_trigger(v_object_type);
            PERFORM claimius._attach_self_root_trigger(v_object_type);
            RAISE NOTICE 'Registered table %', v_object_type;
        END LOOP;

    -- Bulk seed materialized state for any registered table with existing data
    PERFORM set_config('claimius.replay_mode', 'true', TRUE);
    BEGIN
        FOREACH v_object_type IN ARRAY v_new LOOP
                IF position('.' IN v_object_type) = 0 THEN
                    v_object_type := 'public.' || v_object_type;
                END IF;
                PERFORM claimius._bulk_seed_user_object(v_object_type);
                RAISE NOTICE 'Seeded user_object for %', v_object_type;
            END LOOP;
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('claimius.replay_mode', 'false', TRUE);
        RAISE;
    END;
    PERFORM set_config('claimius.replay_mode', 'false', TRUE);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.init_claimius_tables(VARIADIC p_object_types text[]) IS 'Registers external tables. Idempotent. Called by implementer migrations.';

-- _bulk_seed_user_object
-- For a registered table with existing rows, populates user_object,
-- object_users, and user_users for every (user, object) pair where access
-- exists. Inherits the caller's replay_mode setting; callers run this with
-- replay_mode = true so emit_sync_event short circuits and the bulk seed
-- produces no sync events. Per-row cost is bounded because the helpers
-- _affected_users_for_object and _build_grants_for_object both use indexed
-- joins against the inheritance_info closure table.
CREATE OR REPLACE FUNCTION claimius._bulk_seed_user_object(p_object_type TEXT)
    RETURNS VOID AS $$
DECLARE
    v_schema TEXT;
    v_table TEXT;
    v_parts TEXT[];
    v_row_count INTEGER := 0;
    v_has_app_id BOOLEAN;
    v_user RECORD;
    v_obj RECORD;
    v_sql TEXT;
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    SELECT t.has_app_id INTO v_has_app_id
    FROM claimius.table_info t WHERE t.object_type = p_object_type;

    IF v_has_app_id THEN
        v_sql := format('SELECT id, app_id FROM %I.%I WHERE sa_deleted_at IS NULL', v_schema, v_table);
    ELSE
        v_sql := format('SELECT id, claimius.get_app_id() AS app_id FROM %I.%I WHERE sa_deleted_at IS NULL', v_schema, v_table);
    END IF;
    FOR v_obj IN EXECUTE v_sql LOOP
            FOR v_user IN
                SELECT user_id FROM claimius._affected_users_for_object(v_obj.app_id, p_object_type, v_obj.id)
                LOOP
                    PERFORM claimius.recompute_user_object(v_obj.app_id, v_user.user_id, p_object_type, v_obj.id);
                END LOOP;
            v_row_count := v_row_count + 1;
            IF v_row_count % 100 = 0 THEN
                RAISE NOTICE '  ... seeded % rows of %', v_row_count, p_object_type;
            END IF;
        END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._bulk_seed_user_object(p_object_type text) IS 'Seeds user_object for an existing table at registration time.';

-- ----------------------------------------------------------------------------
-- recompute_state
-- Rebuilds inheritance_info trees and user_object materialization for every
-- registered table from live data. Idempotent. Use after a bulk write that
-- ran with claimius.replay_mode = 'true', or any time materialization needs
-- to be reconciled with current rows.
--
-- Self contained: reads the registry from claimius.table_info; takes no
-- arguments; assumes init_claimius_internal() and init_claimius_tables(...)
-- have already registered the relevant tables. If table_info is empty the
-- function is a no-op.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION claimius.recompute_state()
    RETURNS VOID AS $$
DECLARE
    v_root    UUID;
    v_table   RECORD;
    v_sql     TEXT;
    v_id      UUID;
BEGIN
    PERFORM set_config('claimius.replay_mode', 'true', TRUE);
    BEGIN
        FOR v_root IN
            SELECT id FROM claimius.organization
            WHERE sa_owner_id = id AND sa_deleted_at IS NULL
            LOOP
                PERFORM claimius.build_ownership_tree(v_root);
            END LOOP;

        FOR v_root IN
            SELECT id FROM claimius.location
            WHERE sa_parent_id = id AND sa_deleted_at IS NULL
            LOOP
                PERFORM claimius.build_location_tree(v_root);
            END LOOP;

        FOR v_table IN
            SELECT object_type, schema_name, table_name
            FROM claimius.table_info
            WHERE has_sa_parent_id
              AND has_sa_root_id
              AND object_type NOT IN ('claimius.organization', 'claimius.location')
            LOOP
                v_sql := format(
                        'SELECT id FROM %I.%I WHERE sa_parent_id = id AND sa_deleted_at IS NULL',
                        v_table.schema_name, v_table.table_name
                         );
                FOR v_id IN EXECUTE v_sql LOOP
                        PERFORM claimius.build_parenthood_tree(v_table.object_type, v_id);
                    END LOOP;
            END LOOP;

        FOR v_table IN
            SELECT ti.object_type
            FROM claimius.table_info ti
            WHERE ti.has_sa_deleted_at
              AND EXISTS (
                SELECT 1 FROM claimius.claim_object co
                WHERE co.object_type = ti.object_type
                  AND co.sa_deleted_at IS NULL
            )
            LOOP
                PERFORM claimius._bulk_seed_user_object(v_table.object_type);
            END LOOP;
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('claimius.replay_mode', 'false', TRUE);
        RAISE;
    END;
    PERFORM set_config('claimius.replay_mode', 'false', TRUE);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.recompute_state() IS 'Rebuilds inheritance_info and user_object for every registered table from live data. Idempotent. Run after bulk writes that bypassed calc triggers.';

-- ----------------------------------------------------------------------------
-- init_claimius_internal
-- Registers all claimius.* tables in table_info. Called once at the end of
-- claimius schema bootstrap (VX.0__init.sql). Not callable by implementers.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.init_claimius_internal()
    RETURNS VOID AS $$
DECLARE
    v_internal_tables TEXT[] := ARRAY[
        'claimius.samna_app',
        'claimius.samna_user',
        'claimius.samna_client',
        'claimius.samna_secret',
        'claimius.organization',
        'claimius.location',
        'claimius.claim',
        'claimius.user_claim',
        'claimius.claim_object',
        'claimius.audit',
        'claimius.object_field',
        'claimius.user_field',
        'claimius.user_relation'
        ];
    v_t TEXT;
BEGIN
    FOREACH v_t IN ARRAY v_internal_tables LOOP
            PERFORM claimius._register_table_info(v_t, TRUE);
        END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.init_claimius_internal() IS 'Registers internal claimius.* tables in table_info. Called once at schema bootstrap.';

-- ----------------------------------------------------------------------------
-- create_root_organization
-- Creates a new root organization (one with no parent in the ownership
-- tree). Two phase self reference is handled internally so callers do not
-- need to know the convention.
--
-- Returns the inserted row as jsonb keyed by table name. Idempotent on
-- (app_id, name): if a non deleted org with the same name already exists in
-- the app, returns that row instead of creating a new one.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.create_root_organization(
    p_app_id            UUID,
    p_name              TEXT,
    p_actor_user_claim_id UUID,
    p_description       TEXT DEFAULT NULL,
    p_type              TEXT DEFAULT 'standard',
    p_id                UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_row   claimius.organization;
BEGIN
    p_id := claimius.ensure_uuid_null(p_id);

    -- Idempotency: existing root org with same (app, name)?
    SELECT * INTO v_row
    FROM claimius.organization
    WHERE app_id = p_app_id
      AND name = p_name
      AND sa_deleted_at IS NULL
      AND sa_owner_id = id
    LIMIT 1;

    IF v_row.id IS NOT NULL THEN
        RETURN jsonb_build_object('organization', to_jsonb(v_row));
    END IF;

    INSERT INTO claimius.organization (
        id, app_id, name, description, type,
        sa_level, sa_created_by
    ) VALUES (
                 coalesce(p_id, gen_random_uuid()), p_app_id, p_name, p_description, p_type,
                 0, p_actor_user_claim_id
             )
    RETURNING * INTO v_row;

    RETURN jsonb_build_object('organization', to_jsonb(v_row));
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.create_root_organization(UUID, TEXT, UUID, TEXT, TEXT, UUID) IS 'Creates a new root organization with self referencing sa_owner_id and sa_root_id. Idempotent on (app_id, name).';

-- ----------------------------------------------------------------------------
-- init_prophet
-- Bootstrap a fresh claimius deployment as a prophet. Creates the system
-- app, system organization (self rooted), system user, system claim, and
-- wires up the bootstrap user_claim and claim_object. Idempotent.
--
-- Per app cryptographic material is generated externally in Go and passed
-- in. Claimius does not generate keys.
--
-- App and org reference each other via sa_owner_id (app->org) and app_id
-- (org->app). We resolve the chicken-and-egg by inserting both with
-- generated placeholder uuids and then reconciling with UPDATEs.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.init_prophet(
    p_system_app_slug       TEXT,
    p_system_app_name       TEXT,
    p_system_app_private_key  TEXT,
    p_system_app_private_seed TEXT,
    p_system_user_id        UUID DEFAULT NULL,
    p_system_app_redirect_uri  TEXT DEFAULT '',
    p_system_app_sync_uri      TEXT DEFAULT '',
    p_system_app_contact_email TEXT DEFAULT NULL,
    p_system_app_image      TEXT DEFAULT NULL,
    p_system_app_provider_ids UUID[] DEFAULT ARRAY[]::UUID[],
    p_system_app_style      JSONB DEFAULT NULL,
    p_system_app_description TEXT DEFAULT 'System app',
    p_system_org_name       TEXT DEFAULT 'System',
    p_system_claim_name     TEXT DEFAULT 'System Administrator',
    p_system_claim_id       UUID DEFAULT NULL,
    p_default_claim         JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_app_id            UUID;
    v_org_id            UUID;
    v_claim_id          UUID;
    v_default_claim_id  UUID;
    v_user_claim_id     UUID;
    v_pre_app_id        UUID;
    v_pre_org_id        UUID;
    v_default_name      TEXT;
    v_default_desc      TEXT;
    v_default_level     INTEGER;
BEGIN
    p_system_user_id  := COALESCE(claimius.ensure_uuid_null(p_system_user_id),  gen_random_uuid());
    p_system_claim_id := COALESCE(claimius.ensure_uuid_null(p_system_claim_id), gen_random_uuid());

    -- Validate the required default claim metadata. The system claim is
    -- created with hardcoded properties; the default claim (granted to every
    -- regular user on first login via ensure_app_user) is implementer defined.
    IF p_default_claim IS NULL THEN
        RAISE EXCEPTION 'init_prophet: p_default_claim is required and must contain name and description.';
    END IF;
    v_default_name  := p_default_claim ->> 'name';
    v_default_desc  := p_default_claim ->> 'description';
    v_default_level := coalesce((p_default_claim ->> 'sa_access')::INTEGER, 4);
    IF v_default_name IS NULL OR v_default_name = '' THEN
        RAISE EXCEPTION 'init_prophet: p_default_claim.name is required.';
    END IF;
    IF v_default_desc IS NULL OR v_default_desc = '' THEN
        RAISE EXCEPTION 'init_prophet: p_default_claim.description is required.';
    END IF;

    -- Pre-generate the ids so app and org can reference each other in their
    -- INSERTs even though they create circular references.
    v_pre_app_id := gen_random_uuid();
    v_pre_org_id := gen_random_uuid();

    -- 1. system app, with sa_owner_id pointing at the future system org.
    -- app_secret is intentionally NOT set here. It's the API key that
    -- disciples (or other consumers) authenticate with against this prophet's
    -- sync endpoints, generated externally by the implementing service and
    -- written to samna_app.app_secret on demand. secret_version uses its
    -- schema default until the first secret is issued.
    INSERT INTO claimius.samna_app (
        id, slug, name, description, contact_email, app_image,
        redirect_uri, sync_uri, provider_ids, status,
        private_key, private_seed,
        style, sa_owner_id, sa_created_by
    ) VALUES (
                 v_pre_app_id, p_system_app_slug, p_system_app_name,
                 p_system_app_description, p_system_app_contact_email, p_system_app_image,
                 p_system_app_redirect_uri, p_system_app_sync_uri, p_system_app_provider_ids,
                 'active'::claimius.app_status,
                 p_system_app_private_key, p_system_app_private_seed,
                 p_system_app_style, v_pre_org_id, p_system_user_id
             )
    ON CONFLICT (slug) DO UPDATE SET
                                     name = EXCLUDED.name,
                                     description = EXCLUDED.description,
                                     contact_email = EXCLUDED.contact_email,
                                     sa_updated_at = now()
    RETURNING id INTO v_app_id;

    -- 2. system samna_user
    -- Partial unique index (user_id, app_id) WHERE sa_deleted_at IS NULL means
    -- ON CONFLICT can't infer an arbiter cleanly, so SELECT-then-INSERT.
    IF NOT EXISTS (
        SELECT 1 FROM claimius.samna_user
        WHERE user_id = p_system_user_id AND app_id = v_app_id AND sa_deleted_at IS NULL
    ) THEN
        INSERT INTO claimius.samna_user (user_id, app_id, status, type, first_name, last_name)
        VALUES (p_system_user_id, v_app_id, 'active', 'system', 'System', 'User');
    END IF;

    -- 3. system organization, self rooted, owned by the system app
    SELECT id INTO v_org_id FROM claimius.organization
    WHERE app_id = v_app_id AND type = 'system' AND sa_deleted_at IS NULL
    LIMIT 1;

    IF v_org_id IS NULL THEN
        INSERT INTO claimius.organization (
            id, app_id, name, type, sa_owner_id, sa_root_id, sa_level, sa_created_by
        ) VALUES (
                     v_pre_org_id, v_app_id, p_system_org_name, 'system',
                     v_pre_org_id, v_pre_org_id, 0, p_system_user_id
                 )
        RETURNING id INTO v_org_id;
    END IF;

    -- 4. reconcile: app's sa_owner_id should match the actual system org id
    UPDATE claimius.samna_app SET sa_owner_id = v_org_id WHERE id = v_app_id AND sa_owner_id <> v_org_id;

    -- 5. ensure ownership tree closure self-edge for the system org
    INSERT INTO claimius.inheritance_info (
        tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
    ) VALUES (
        'ownership', v_org_id, 'claimius.organization', v_org_id, 'claimius.organization', v_org_id, 0
    ) ON CONFLICT DO NOTHING;

    -- 6. system claim (sidelined: granted only to the system user)
    SELECT id INTO v_claim_id FROM claimius.claim
    WHERE app_id = v_app_id AND name = p_system_claim_name AND sa_deleted_at IS NULL;

    IF v_claim_id IS NULL THEN
        INSERT INTO claimius.claim (
            id, app_id, name, description, sa_access, inherits, type,
            sa_owner_id, sa_root_id, sa_created_by
        ) VALUES (
                     p_system_claim_id, v_app_id, p_system_claim_name,
                     'Full access to claimius', 15, TRUE, 'system',
                     v_org_id, v_org_id, p_system_user_id
                 )
        RETURNING id INTO v_claim_id;
    END IF;

    -- 6b. default claim (granted to every regular user on first login via
    -- ensure_app_user). No claim_object binding, no inheritance: it is a
    -- "you have an account" marker by default. Implementer defines name,
    -- description, and level via p_default_claim.
    SELECT id INTO v_default_claim_id FROM claimius.claim
    WHERE app_id = v_app_id AND name = v_default_name AND sa_deleted_at IS NULL;

    IF v_default_claim_id IS NULL THEN
        INSERT INTO claimius.claim (
            app_id, name, description, sa_access, inherits, type,
            sa_owner_id, sa_root_id, sa_created_by
        ) VALUES (
                     v_app_id, v_default_name, v_default_desc, v_default_level,
                     FALSE, 'user',
                     v_org_id, v_org_id, p_system_user_id
                 )
        RETURNING id INTO v_default_claim_id;
    END IF;

    -- 7. attach default claim_id to the system app. This is the claim every
    -- regular user receives via ensure_app_user. The system claim stays
    -- sidelined and is granted only to the system user below.
    UPDATE claimius.samna_app SET claim_id = v_default_claim_id
    WHERE id = v_app_id AND (claim_id IS NULL OR claim_id <> v_default_claim_id);

    -- 8. bind claim to system org
    -- claim_object has no unique constraint, so SELECT-then-INSERT.
    IF NOT EXISTS (
        SELECT 1 FROM claimius.claim_object
        WHERE app_id = v_app_id
          AND claim_id = v_claim_id
          AND object_id = v_org_id
          AND object_type = 'claimius.organization'
          AND sa_deleted_at IS NULL
    ) THEN
        INSERT INTO claimius.claim_object (
            app_id, claim_id, object_id, object_type,
            sa_owner_id, sa_root_id, sa_created_by, inherits
        ) VALUES (
                     v_app_id, v_claim_id, v_org_id, 'claimius.organization',
                     v_org_id, v_org_id, p_system_user_id, TRUE
                 );
    END IF;

    -- 8b. bind claim to system app directly. Every resource (except users
    -- and the claim itself) carries at least one direct claim_object grant
    -- so that access never depends solely on cascade. inherits = FALSE
    -- because the org binding above already cascades to the app via the
    -- ownership tree; this is an owner anchor, not a cascade source.
    IF NOT EXISTS (
        SELECT 1 FROM claimius.claim_object
        WHERE app_id = v_app_id
          AND claim_id = v_claim_id
          AND object_id = v_app_id
          AND object_type = 'claimius.samna_app'
          AND sa_deleted_at IS NULL
    ) THEN
        INSERT INTO claimius.claim_object (
            app_id, claim_id, object_id, object_type,
            sa_owner_id, sa_root_id, sa_created_by, inherits
        ) VALUES (
                     v_app_id, v_claim_id, v_app_id, 'claimius.samna_app',
                     v_org_id, v_org_id, p_system_user_id, FALSE
                 );
    END IF;

    -- 9. grant claim to system user
    -- Partial unique index on (claim_id, user_id, app_id) WHERE sa_deleted_at IS NULL.
    -- SELECT-then-INSERT, capturing the id either way for the return jsonb.
    SELECT id INTO v_user_claim_id FROM claimius.user_claim
    WHERE app_id = v_app_id
      AND claim_id = v_claim_id
      AND user_id = p_system_user_id
      AND sa_deleted_at IS NULL
    LIMIT 1;

    IF v_user_claim_id IS NULL THEN
        INSERT INTO claimius.user_claim (
            app_id, claim_id, user_id, sa_owner_id, sa_created_by
        ) VALUES (
                     v_app_id, v_claim_id, p_system_user_id, v_org_id, p_system_user_id
                 )
        RETURNING id INTO v_user_claim_id;
    END IF;

    -- 10. prophet_state row for this app, marked as the system app via
    -- system_app_slug. Partial unique index enforces at most one system row.
    INSERT INTO claimius.prophet_state (app_id, last_applied_seq, system_app_slug)
    VALUES (v_app_id, 0, p_system_app_slug)
    ON CONFLICT (app_id) DO UPDATE SET system_app_slug = EXCLUDED.system_app_slug;

    -- 11. role grants for prophet runtime
    PERFORM claimius._grant_prophet_roles();

    -- Build the result: 6 keys, each named after the table the row lives in.
    -- prophet_state and inheritance_info are internal bookkeeping and are
    -- not returned. Re-running init_prophet is idempotent and returns the
    -- current state of these rows.
    DECLARE
        v_result JSONB;
    BEGIN
        SELECT jsonb_build_object(
                       'samna_app',     to_jsonb(a.*),
                       'organization',  to_jsonb(o.*),
                       'samna_user',    to_jsonb(u.*),
                       'claim',         to_jsonb(c.*),
                       'default_claim', to_jsonb(dc.*),
                       'user_claim',    to_jsonb(uc.*),
                       'claim_object',  to_jsonb(co.*)
               )
        INTO v_result
        FROM claimius.samna_app a
                 LEFT JOIN claimius.organization o ON o.id = v_org_id
                 LEFT JOIN claimius.samna_user u ON u.user_id = p_system_user_id AND u.app_id = v_app_id
                 LEFT JOIN claimius.claim c ON c.id = v_claim_id
                 LEFT JOIN claimius.claim dc ON dc.id = v_default_claim_id
                 LEFT JOIN claimius.user_claim uc ON uc.id = v_user_claim_id
                 LEFT JOIN claimius.claim_object co ON co.app_id = v_app_id AND co.claim_id = v_claim_id
            AND co.object_id = v_org_id AND co.object_type = 'claimius.organization'
            AND co.sa_deleted_at IS NULL
        WHERE a.id = v_app_id;

        RAISE NOTICE 'Prophet initialized: app=% org=% claim=% user=%',
            v_app_id, v_org_id, v_claim_id, p_system_user_id;

        RETURN v_result;
    END;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.init_prophet(p_system_app_slug text, p_system_app_name text, p_system_app_private_key text, p_system_app_private_seed text, p_system_user_id uuid, p_system_app_redirect_uri text, p_system_app_sync_uri text, p_system_app_contact_email text, p_system_app_image text, p_system_app_provider_ids uuid[], p_system_app_style jsonb, p_system_app_description text, p_system_org_name text, p_system_claim_name text, p_system_claim_id uuid, p_default_claim jsonb) IS 'Bootstrap function. Sets up system app, org, user, and claim. Idempotent.';

-- ----------------------------------------------------------------------------
-- init_disciple
-- Bootstrap a fresh claimius deployment as a disciple. Records that this
-- instance is a disciple, sets up disciple_state with the slug of the
-- upstream prophet app this disciple mirrors, and grants the
-- disciple_client role. Pass p_disciple_app_slug from an environment
-- variable (e.g. CLAIMIUS_DISCIPLE_APP_SLUG) so the same migration
-- artefact can be deployed against any prophet. The actual data arrives
-- via sync from the prophet.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.init_disciple(
    p_disciple_app_slug TEXT
)
    RETURNS JSONB AS $$
BEGIN
    IF p_disciple_app_slug IS NULL OR p_disciple_app_slug = '' THEN
        RAISE EXCEPTION 'init_disciple: p_disciple_app_slug is required.';
    END IF;

    -- Singleton row in disciple_state. SELECT-then-INSERT, then UPDATE the
    -- slug so re-running init_disciple with a different slug is allowed
    -- (idempotent for the same value, corrective for a wrong one).
    IF NOT EXISTS (SELECT 1 FROM claimius.disciple_state) THEN
        INSERT INTO claimius.disciple_state (last_applied_seq, disciple_app_slug)
        VALUES (0, p_disciple_app_slug);
    ELSE
        UPDATE claimius.disciple_state
        SET disciple_app_slug = p_disciple_app_slug,
            sa_updated_at = now()
        WHERE disciple_app_slug <> p_disciple_app_slug;
    END IF;

    -- Roles: disciple gets reader plus disciple_client
    PERFORM claimius._grant_disciple_roles();

    RAISE NOTICE 'Disciple initialized for app slug %. Sync layer must populate samna_app and other tables from prophet.', p_disciple_app_slug;

    -- Disciples have nothing user meaningful to return: state arrives via
    -- sync. We return an empty jsonb so the function has the same return
    -- type as init_prophet and init_hybrid.
    RETURN '{}'::JSONB;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.init_disciple(p_disciple_app_slug text) IS 'Bootstrap as a disciple. Requires the upstream prophet app slug. State arrives from prophet via sync.';

-- ----------------------------------------------------------------------------
-- init_hybrid
-- Hybrid: instance acts as a disciple to an upstream prophet AND as a
-- prophet for downstream disciples. Combines init_prophet and init_disciple
-- behavior plus role grants for both.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.init_hybrid(
    p_system_app_slug          TEXT,
    p_system_app_name          TEXT,
    p_system_app_private_key   TEXT,
    p_system_app_private_seed  TEXT,
    p_disciple_app_slug        TEXT,
    p_system_user_id           UUID DEFAULT NULL,
    p_system_app_redirect_uri  TEXT DEFAULT '',
    p_system_app_sync_uri      TEXT DEFAULT '',
    p_system_app_contact_email TEXT DEFAULT NULL,
    p_system_app_image         TEXT DEFAULT NULL,
    p_system_app_provider_ids  UUID[] DEFAULT ARRAY[]::UUID[],
    p_system_app_style         JSONB DEFAULT NULL,
    p_system_app_description   TEXT DEFAULT 'System app',
    p_system_org_name          TEXT DEFAULT 'System',
    p_system_claim_name        TEXT DEFAULT 'System Administrator',
    p_system_claim_id          UUID DEFAULT NULL,
    p_default_claim            JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
BEGIN
    v_result := claimius.init_prophet(
            p_system_app_slug, p_system_app_name,
            p_system_app_private_key, p_system_app_private_seed,
            p_system_user_id,
            p_system_app_redirect_uri, p_system_app_sync_uri, p_system_app_contact_email,
            p_system_app_image, p_system_app_provider_ids, p_system_app_style,
            p_system_app_description, p_system_org_name,
            p_system_claim_name, p_system_claim_id,
            p_default_claim
                );
    PERFORM claimius.init_disciple(p_disciple_app_slug);
    PERFORM claimius._grant_hybrid_roles();
    RAISE NOTICE 'Hybrid initialized.';
    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.init_hybrid(p_system_app_slug text, p_system_app_name text, p_system_app_private_key text, p_system_app_private_seed text, p_disciple_app_slug text, p_system_user_id uuid, p_system_app_redirect_uri text, p_system_app_sync_uri text, p_system_app_contact_email text, p_system_app_image text, p_system_app_provider_ids uuid[], p_system_app_style jsonb, p_system_app_description text, p_system_org_name text, p_system_claim_name text, p_system_claim_id uuid, p_default_claim jsonb) IS 'Bootstrap as a hybrid (prophet + disciple).';

-- ----------------------------------------------------------------------------
-- Role grant helpers
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius._grant_prophet_roles()
    RETURNS VOID AS $$
BEGIN
    -- Reader: EXECUTE on all functions, then revoke the write functions and
    -- the init/admin ones. Reader sees no tables directly.
    EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA claimius TO claimius_reader';
    EXECUTE 'REVOKE EXECUTE ON FUNCTION claimius.create_claim, claimius.update_claim, claimius.remove_claim,
             claimius.assign_claim_user, claimius.update_claim_user, claimius.remove_user_claim,
             claimius.assign_claim_object, claimius.update_claim_object, claimius.remove_claim_object,
             claimius.merge_user, claimius.migrate_root,
             claimius.init_prophet, claimius.init_disciple, claimius.init_hybrid,
             claimius.init_claimius_tables, claimius.init_claimius_internal,
             claimius.recompute_state
             FROM claimius_reader';

    -- Writer: EXECUTE on everything, plus INSERT/UPDATE on tables that do
    -- not have dedicated write functions. The prophet's app code is allowed
    -- to write directly to these tables. Tables WITH write functions
    -- (claim, user_claim, claim_object) get only EXECUTE on the function;
    -- direct writes to those tables are not granted.
    EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA claimius TO claimius_writer';
    EXECUTE 'GRANT INSERT, UPDATE ON
             claimius.samna_app, claimius.samna_user, claimius.samna_client, claimius.samna_secret,
             claimius.organization, claimius.location,
             claimius.object_field, claimius.user_field, claimius.user_relation,
             claimius.prophet_state
             TO claimius_writer';
    EXECUTE 'GRANT INSERT, UPDATE, DELETE ON claimius.claim_graph_cache TO claimius_writer';
    EXECUTE 'GRANT INSERT, UPDATE, DELETE ON claimius.claim_graph_cache TO claimius_reader';
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA claimius TO claimius_writer';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION claimius._grant_disciple_roles()
    RETURNS VOID AS $$
BEGIN
    EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA claimius TO claimius_reader';
    EXECUTE 'REVOKE EXECUTE ON FUNCTION claimius.create_claim, claimius.update_claim, claimius.remove_claim,
             claimius.assign_claim_user, claimius.update_claim_user, claimius.remove_user_claim,
             claimius.assign_claim_object, claimius.update_claim_object, claimius.remove_claim_object,
             claimius.merge_user, claimius.migrate_root,
             claimius.init_prophet, claimius.init_disciple, claimius.init_hybrid,
             claimius.init_claimius_tables, claimius.init_claimius_internal,
             claimius.recompute_state
             FROM claimius_reader';
    EXECUTE 'GRANT INSERT, UPDATE, DELETE ON claimius.user_object, claimius.object_users, claimius.user_users,
             claimius.disciple_state, claimius.samna_user, claimius.samna_client,
             claimius.samna_secret, claimius.samna_app, claimius.organization, claimius.location,
             claimius.claim, claimius.user_claim, claimius.claim_object,
             claimius.object_field, claimius.user_field, claimius.user_relation,
             claimius.audit, claimius.inheritance_info, claimius.table_info,
             claimius.claim_graph_cache
             TO claimius_disciple_client';
    EXECUTE 'GRANT INSERT, UPDATE, DELETE ON claimius.claim_graph_cache TO claimius_reader';
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA claimius TO claimius_disciple_client';
    EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA claimius TO claimius_disciple_client';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION claimius._grant_hybrid_roles()
    RETURNS VOID AS $$
BEGIN
    PERFORM claimius._grant_prophet_roles();
    PERFORM claimius._grant_disciple_roles();
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- ensure_app_user
-- Helper for prophet apps. When a user logs into an app for the first time,
-- creates the per app samna_user row keyed by (user_id, app_id). If the app
-- has a default claim configured (samna_app.claim_id), grants it to the user
-- as part of the same call. Idempotent: re-running returns the existing row
-- and existing user_claim.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.ensure_app_user(
    p_user_id    UUID,
    p_app_id     UUID,
    p_first_name TEXT DEFAULT NULL,
    p_last_name  TEXT DEFAULT NULL,
    p_user_name  TEXT DEFAULT NULL,
    p_user_image TEXT DEFAULT NULL,
    p_email      TEXT DEFAULT NULL,
    p_phone      TEXT DEFAULT NULL,
    p_external_id TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_user_row    claimius.samna_user;
    v_uc_row      claimius.user_claim;
    v_default_claim_id UUID;
    v_default_claim_owner UUID;
BEGIN
    p_user_id := claimius.ensure_uuid_null(p_user_id);

    -- Find or insert the samna_user row
    SELECT * INTO v_user_row FROM claimius.samna_user
    WHERE user_id = p_user_id AND app_id = p_app_id AND sa_deleted_at IS NULL;

    IF NOT FOUND THEN
        INSERT INTO claimius.samna_user (
            user_id, app_id, first_name, last_name, user_name, user_image,
            email, phone, external_id, status, type
        )
        VALUES (
                   COALESCE(p_user_id, gen_random_uuid()),
                   p_app_id, p_first_name, p_last_name, p_user_name, p_user_image,
                   p_email, p_phone, p_external_id, 'active', 'user'
               )
        RETURNING * INTO v_user_row;
    END IF;

    -- Look up the app's default claim
    SELECT a.claim_id, c.sa_owner_id
    INTO v_default_claim_id, v_default_claim_owner
    FROM claimius.samna_app a
             LEFT JOIN claimius.claim c ON c.id = a.claim_id AND c.sa_deleted_at IS NULL
    WHERE a.id = p_app_id;

    -- Grant the default claim if one is configured. Idempotent: if the user
    -- already has a live user_claim for this claim, return the existing one.
    IF v_default_claim_id IS NOT NULL THEN
        SELECT * INTO v_uc_row FROM claimius.user_claim
        WHERE user_id = v_user_row.user_id
          AND app_id = p_app_id
          AND claim_id = v_default_claim_id
          AND sa_deleted_at IS NULL
        LIMIT 1;

        IF NOT FOUND THEN
            INSERT INTO claimius.user_claim (
                app_id, claim_id, user_id, sa_owner_id, sa_created_by
            ) VALUES (
                         p_app_id, v_default_claim_id, v_user_row.user_id,
                         v_default_claim_owner,
                         v_user_row.user_id  -- bootstrap exception: actor is the user themselves on first login
                     )
            RETURNING * INTO v_uc_row;
        END IF;

        RETURN jsonb_build_object(
                'samna_user', to_jsonb(v_user_row),
                'user_claim', to_jsonb(v_uc_row)
               );
    END IF;

    -- App has no default claim configured: just return the samna_user row.
    RETURN jsonb_build_object('samna_user', to_jsonb(v_user_row));
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.ensure_app_user(p_user_id uuid, p_app_id uuid, p_first_name text, p_last_name text, p_user_name text, p_user_image text, p_email text, p_phone text, p_external_id text) IS 'Creates per app samna_user row and grants the app default claim. Idempotent.';