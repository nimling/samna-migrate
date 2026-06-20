-- ============================================================================
-- Claimius V2.2 Internal Functions
-- ----------------------------------------------------------------------------
-- Functions used internally by triggers, init, and other claimius internals.
-- Not exposed to consumers. These functions assume valid inputs and may
-- raise on misuse.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Tree builders. Used by init, hierarchy reparenting, and bulk operations.
-- Each rewrites every edge in inheritance_info for the given tree from live
-- data. Self-edges (depth = 0) included so a node is its own ancestor.
-- ----------------------------------------------------------------------------

-- build_ownership_tree
-- Rewrites the ownership tree closure rooted at p_root_id from live data.
-- Includes org-org edges plus edges from every registered table whose rows
-- point at any org in the tree via sa_owner_id.
CREATE OR REPLACE FUNCTION claimius.build_ownership_tree(p_root_id UUID)
    RETURNS VOID AS $$
BEGIN
    DELETE FROM claimius.inheritance_info
    WHERE tree_type = 'ownership' AND root_id = p_root_id;

    -- Org-org edges. Walk down recursively, recording the path of ancestors
    -- to each node, then explode the path into one edge per ancestor.
    INSERT INTO claimius.inheritance_info (
        tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
    )
    WITH RECURSIVE org_paths AS (
        SELECT id AS node_id, ARRAY[id]::UUID[] AS path
        FROM claimius.organization
        WHERE id = p_root_id AND sa_deleted_at IS NULL
        UNION ALL
        SELECT o.id, p.path || o.id
        FROM claimius.organization o
                 JOIN org_paths p ON o.sa_owner_id = p.node_id
        WHERE o.id <> o.sa_owner_id AND o.sa_deleted_at IS NULL
    )
    SELECT 'ownership'::claimius.tree_type, p_root_id,
           'claimius.organization'::TEXT, p.path[i]::UUID,
           'claimius.organization'::TEXT, p.node_id,
           array_length(p.path, 1) - i
    FROM org_paths p
             CROSS JOIN LATERAL generate_subscripts(p.path, 1) AS i;

    -- Registered-table edges. For each row r in any registered table whose
    -- owner is in the org tree, emit:
    --   self-edge (r, r, 0)
    --   plus (ancestor_of_r.sa_owner_id, r, depth + 1) for each org ancestor
    INSERT INTO claimius.inheritance_info (
        tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
    )
    SELECT 'ownership'::claimius.tree_type, p_root_id, t.object_type, r.id, t.object_type, r.id, 0
    FROM claimius.table_info t
             CROSS JOIN LATERAL claimius._select_owned_rows(t.object_type, p_root_id) r
    WHERE t.has_sa_owner_id
      AND t.has_sa_deleted_at
      AND t.object_type <> 'claimius.organization'
    UNION ALL
    SELECT 'ownership'::claimius.tree_type, p_root_id, e.ancestor_type, e.ancestor_id, t.object_type, r.id, e.depth + 1
    FROM claimius.table_info t
             CROSS JOIN LATERAL claimius._select_owned_rows(t.object_type, p_root_id) r
             JOIN claimius.inheritance_info e
                  ON e.tree_type = 'ownership'
                      AND e.root_id = p_root_id
                      AND e.descendant_type = 'claimius.organization'
                      AND e.descendant_id = r.sa_owner_id
    WHERE t.has_sa_owner_id
      AND t.has_sa_deleted_at
      AND t.object_type <> 'claimius.organization';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.build_ownership_tree(UUID) IS 'Rewrites ownership tree closure rooted at p_root_id from live data.';

-- build_location_tree
-- Rewrites the location tree closure rooted at p_root_id from live data.
-- Includes location-location edges plus edges from every registered table
-- whose rows point at any location in the tree via sa_location_id.
CREATE OR REPLACE FUNCTION claimius.build_location_tree(p_root_id UUID)
    RETURNS VOID AS $$
BEGIN
    DELETE FROM claimius.inheritance_info
    WHERE tree_type = 'location' AND root_id = p_root_id;

    INSERT INTO claimius.inheritance_info (
        tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
    )
    WITH RECURSIVE loc_paths AS (
        SELECT id AS node_id, ARRAY[id]::UUID[] AS path
        FROM claimius.location
        WHERE id = p_root_id AND sa_deleted_at IS NULL
        UNION ALL
        SELECT l.id, p.path || l.id
        FROM claimius.location l
                 JOIN loc_paths p ON l.sa_parent_id = p.node_id
        WHERE l.id <> l.sa_parent_id AND l.sa_deleted_at IS NULL
    )
    SELECT 'location'::claimius.tree_type, p_root_id,
           'claimius.location'::TEXT, p.path[i]::UUID,
           'claimius.location'::TEXT, p.node_id,
           array_length(p.path, 1) - i
    FROM loc_paths p
             CROSS JOIN LATERAL generate_subscripts(p.path, 1) AS i;

    INSERT INTO claimius.inheritance_info (
        tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
    )
    SELECT 'location'::claimius.tree_type, p_root_id, t.object_type, r.id, t.object_type, r.id, 0
    FROM claimius.table_info t
             CROSS JOIN LATERAL claimius._select_located_rows(t.object_type, p_root_id) r
    WHERE t.has_sa_location_id
      AND t.has_sa_deleted_at
    UNION ALL
    SELECT 'location'::claimius.tree_type, p_root_id, e.ancestor_type, e.ancestor_id, t.object_type, r.id, e.depth + 1
    FROM claimius.table_info t
             CROSS JOIN LATERAL claimius._select_located_rows(t.object_type, p_root_id) r
             JOIN claimius.inheritance_info e
                  ON e.tree_type = 'location'
                      AND e.root_id = p_root_id
                      AND e.descendant_type = 'claimius.location'
                      AND e.descendant_id = r.sa_location_id
    WHERE t.has_sa_location_id
      AND t.has_sa_deleted_at;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.build_location_tree(UUID) IS 'Rewrites location tree closure rooted at p_root_id from live data.';

-- build_parenthood_tree
-- Rewrites the parenthood tree closure for one root of a self referencing
-- registered table. Walks the table's sa_parent_id chain only.
CREATE OR REPLACE FUNCTION claimius.build_parenthood_tree(p_object_type TEXT, p_root_id UUID)
    RETURNS VOID AS $$
DECLARE
    v_schema TEXT;
    v_table TEXT;
    v_parts TEXT[];
    v_sql TEXT;
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    DELETE FROM claimius.inheritance_info
    WHERE tree_type = 'parenthood' AND root_id = p_root_id AND ancestor_type = p_object_type;

    v_sql := format($f$
        INSERT INTO claimius.inheritance_info (
            tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
        )
        WITH RECURSIVE node_paths AS (
            SELECT id AS node_id, ARRAY[id]::UUID[] AS path
            FROM %I.%I
            WHERE id = $1 AND sa_deleted_at IS NULL
            UNION ALL
            SELECT t.id, p.path || t.id
            FROM %I.%I t
            JOIN node_paths p ON t.sa_parent_id = p.node_id
            WHERE t.id <> t.sa_parent_id AND t.sa_deleted_at IS NULL
        )
        SELECT 'parenthood'::claimius.tree_type, $1,
               %L::TEXT, p.path[i]::UUID,
               %L::TEXT, p.node_id,
               array_length(p.path, 1) - i
        FROM node_paths p
                 CROSS JOIN LATERAL generate_subscripts(p.path, 1) AS i
    $f$, v_schema, v_table, v_schema, v_table, p_object_type, p_object_type);

    EXECUTE v_sql USING p_root_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.build_parenthood_tree(TEXT, UUID) IS 'Rewrites parenthood tree closure for one root of a self referencing registered table.';

-- _select_owned_rows
-- Returns (id, sa_owner_id) for live rows of an object_type whose owner is
-- in the same root tree as p_root_id. Implemented via dynamic SQL.
CREATE OR REPLACE FUNCTION claimius._select_owned_rows(p_object_type TEXT, p_root_id UUID)
    RETURNS TABLE(id UUID, sa_owner_id UUID) AS $$
DECLARE
    v_schema TEXT;
    v_table TEXT;
    v_parts TEXT[];
    v_sql TEXT;
    v_has_deleted BOOLEAN;
    v_deleted_clause TEXT;
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    -- Look up whether this table has sa_deleted_at. Audit and similar
    -- append-only tables don't, so we omit the soft-delete filter for them.
    SELECT has_sa_deleted_at INTO v_has_deleted
    FROM claimius.table_info WHERE object_type = p_object_type;

    v_deleted_clause := CASE WHEN coalesce(v_has_deleted, FALSE)
                                 THEN 'AND r.sa_deleted_at IS NULL'
                             ELSE ''
        END;

    v_sql := format($f$
        WITH RECURSIVE org_tree AS (
            SELECT id FROM claimius.organization WHERE id = $1 AND sa_deleted_at IS NULL
            UNION ALL
            SELECT o.id FROM claimius.organization o JOIN org_tree t ON o.sa_owner_id = t.id
            WHERE o.id <> o.sa_owner_id AND o.sa_deleted_at IS NULL
        )
        SELECT r.id::UUID, r.sa_owner_id::UUID
        FROM %I.%I r
        WHERE r.sa_owner_id IN (SELECT id FROM org_tree)
          %s
    $f$, v_schema, v_table, v_deleted_clause);
    RETURN QUERY EXECUTE v_sql USING p_root_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- _select_located_rows
-- Returns (id, sa_location_id) for live rows of an object_type whose
-- location is in the same root tree as p_root_id.
CREATE OR REPLACE FUNCTION claimius._select_located_rows(p_object_type TEXT, p_root_id UUID)
    RETURNS TABLE(id UUID, sa_location_id UUID) AS $$
DECLARE
    v_schema TEXT;
    v_table TEXT;
    v_parts TEXT[];
    v_sql TEXT;
    v_has_deleted BOOLEAN;
    v_deleted_clause TEXT;
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    SELECT has_sa_deleted_at INTO v_has_deleted
    FROM claimius.table_info WHERE object_type = p_object_type;

    v_deleted_clause := CASE WHEN coalesce(v_has_deleted, FALSE)
                                 THEN 'AND r.sa_deleted_at IS NULL'
                             ELSE ''
        END;

    v_sql := format($f$
        WITH RECURSIVE loc_tree AS (
            SELECT id FROM claimius.location WHERE id = $1 AND sa_deleted_at IS NULL
            UNION ALL
            SELECT l.id FROM claimius.location l JOIN loc_tree t ON l.sa_parent_id = t.id
            WHERE l.id <> l.sa_parent_id AND l.sa_deleted_at IS NULL
        )
        SELECT r.id::UUID, r.sa_location_id::UUID
        FROM %I.%I r
        WHERE r.sa_location_id IN (SELECT id FROM loc_tree)
          %s
    $f$, v_schema, v_table, v_deleted_clause);
    RETURN QUERY EXECUTE v_sql USING p_root_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- ----------------------------------------------------------------------------
-- Registration helpers
-- ----------------------------------------------------------------------------

-- _app_id_for_row
-- Returns the app_id for a registered row. Reads the row's app_id column
-- if the table has one; otherwise infers it from claimius.get_app_id().
-- Used by every trigger that needs to scope a row's effects to an app.
CREATE OR REPLACE FUNCTION claimius._app_id_for_row(p_object_type TEXT, p_row JSONB)
    RETURNS UUID AS $$
DECLARE
    v_has_app_id BOOLEAN;
BEGIN
    SELECT t.has_app_id INTO v_has_app_id
    FROM claimius.table_info t
    WHERE t.object_type = p_object_type;

    IF v_has_app_id THEN
        RETURN (p_row ->> 'app_id')::UUID;
    END IF;

    RETURN claimius.get_app_id();
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION claimius._app_id_for_row(TEXT, JSONB) IS 'Resolves a row''s app_id: from the row when the table has the column, otherwise from claimius.get_app_id().';

-- _register_table_info
-- Inspects a table's columns, validates required columns, and populates the
-- table_info row. Raises if required columns are missing.
CREATE OR REPLACE FUNCTION claimius._register_table_info(p_object_type TEXT, p_is_internal BOOLEAN)
    RETURNS VOID AS $$
DECLARE
    v_schema            TEXT;
    v_table             TEXT;
    v_parts             TEXT[];
    v_has_owner         BOOLEAN;
    v_has_location      BOOLEAN;
    v_has_parent        BOOLEAN;
    v_has_root          BOOLEAN;
    v_has_created_by    BOOLEAN;
    v_has_deleted_at    BOOLEAN;
    v_has_created_at    BOOLEAN;
    v_has_updated_at    BOOLEAN;
    v_has_app_id        BOOLEAN;
    v_has_name          BOOLEAN;
    v_has_description   BOOLEAN;
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    -- table must exist
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = v_schema AND table_name = v_table
    ) THEN
        RAISE EXCEPTION 'Table %.% does not exist', v_schema, v_table;
    END IF;

    v_has_owner       := claimius.table_has_column(p_object_type, 'sa_owner_id');
    v_has_location    := claimius.table_has_column(p_object_type, 'sa_location_id');
    v_has_parent      := claimius.table_has_column(p_object_type, 'sa_parent_id');
    v_has_root        := claimius.table_has_column(p_object_type, 'sa_root_id');
    v_has_created_by  := claimius.table_has_column(p_object_type, 'sa_created_by');
    v_has_deleted_at  := claimius.table_has_column(p_object_type, 'sa_deleted_at');
    v_has_created_at  := claimius.table_has_column(p_object_type, 'sa_created_at');
    v_has_updated_at  := claimius.table_has_column(p_object_type, 'sa_updated_at');
    v_has_app_id      := claimius.table_has_column(p_object_type, 'app_id');
    v_has_name        := claimius.table_has_column(p_object_type, 'name');
    v_has_description := claimius.table_has_column(p_object_type, 'description');

    -- Required columns for external tables. Internal tables are exempt
    -- because they include claimius internal computed tables that follow
    -- different rules.
    IF NOT p_is_internal THEN
        IF NOT v_has_owner THEN
            RAISE EXCEPTION 'Table % missing required column sa_owner_id', p_object_type;
        END IF;
        IF NOT v_has_created_by THEN
            RAISE EXCEPTION 'Table % missing required column sa_created_by', p_object_type;
        END IF;
        IF NOT v_has_created_at THEN
            RAISE EXCEPTION 'Table % missing required column sa_created_at', p_object_type;
        END IF;
        IF NOT v_has_updated_at THEN
            RAISE EXCEPTION 'Table % missing required column sa_updated_at', p_object_type;
        END IF;
        IF NOT v_has_deleted_at THEN
            RAISE EXCEPTION 'Table % missing required column sa_deleted_at', p_object_type;
        END IF;
        -- sa_parent_id and sa_root_id must come together
        IF v_has_parent <> v_has_root THEN
            RAISE EXCEPTION 'Table % must have both sa_parent_id and sa_root_id, or neither', p_object_type;
        END IF;

        -- Tables without app_id rely on claimius.get_app_id() at runtime to
        -- determine scope. That works only when the deployment hosts a
        -- single app's data: pure disciple, hybrid, or prophet with only
        -- the system app. On a prophet hosting non system apps,
        -- get_app_id() returns the system app id, which would mis-scope
        -- writes to other hosted apps. Reject the registration in that
        -- case so the implementer adds an app_id column.
        IF NOT v_has_app_id THEN
            IF EXISTS (SELECT 1 FROM claimius.prophet_state WHERE system_app_slug IS NOT NULL)
                AND EXISTS (
                    SELECT 1 FROM claimius.samna_app a
                                      JOIN claimius.prophet_state p ON p.system_app_slug IS NOT NULL
                    WHERE a.slug <> p.system_app_slug
                      AND a.sa_deleted_at IS NULL
                ) THEN
                RAISE EXCEPTION 'Table % has no app_id column but this prophet hosts non system apps; add an app_id column to disambiguate row scope', p_object_type;
            END IF;
        END IF;
    END IF;

    INSERT INTO claimius.table_info (
        schema_name, table_name, is_internal,
        has_sa_owner_id, has_sa_location_id, has_sa_parent_id, has_sa_root_id,
        has_sa_created_by, has_sa_deleted_at, has_sa_created_at, has_sa_updated_at,
        has_app_id, has_name, has_description
    ) VALUES (
                 v_schema, v_table, p_is_internal,
                 v_has_owner, v_has_location, v_has_parent, v_has_root,
                 v_has_created_by, v_has_deleted_at, v_has_created_at, v_has_updated_at,
                 v_has_app_id, v_has_name, v_has_description
             )
    ON CONFLICT (object_type) DO UPDATE SET
                                            is_internal = EXCLUDED.is_internal,
                                            has_sa_owner_id = EXCLUDED.has_sa_owner_id,
                                            has_sa_location_id = EXCLUDED.has_sa_location_id,
                                            has_sa_parent_id = EXCLUDED.has_sa_parent_id,
                                            has_sa_root_id = EXCLUDED.has_sa_root_id,
                                            has_sa_created_by = EXCLUDED.has_sa_created_by,
                                            has_sa_deleted_at = EXCLUDED.has_sa_deleted_at,
                                            has_sa_created_at = EXCLUDED.has_sa_created_at,
                                            has_sa_updated_at = EXCLUDED.has_sa_updated_at,
                                            has_app_id = EXCLUDED.has_app_id,
                                            has_name = EXCLUDED.has_name,
                                            has_description = EXCLUDED.has_description,
                                            sa_updated_at = now();
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._register_table_info(TEXT, BOOLEAN) IS 'Registers a table in table_info, validating required columns.';

-- _attach_calc_trigger
-- Attaches the appropriate calc trigger to a registered table. Drops any
-- existing trigger first so the operation is idempotent.
CREATE OR REPLACE FUNCTION claimius._attach_calc_trigger(p_object_type TEXT)
    RETURNS VOID AS $$
DECLARE
    v_schema        TEXT;
    v_table         TEXT;
    v_parts         TEXT[];
    v_has_parent    BOOLEAN;
    v_has_root      BOOLEAN;
    v_func_name     TEXT;
    v_trigger_name  TEXT := 'tg_calc_access';
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    SELECT t.has_sa_parent_id, t.has_sa_root_id
    INTO v_has_parent, v_has_root
    FROM claimius.table_info t WHERE t.object_type = p_object_type;

    IF v_has_parent AND v_has_root THEN
        v_func_name := 'claimius.calc_hierarchical_access';
    ELSE
        v_func_name := 'claimius.calc_object_access';
    END IF;

    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_trigger_name, v_schema, v_table);
    EXECUTE format(
            'CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION %s()',
            v_trigger_name, v_schema, v_table, v_func_name
            );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._attach_calc_trigger(TEXT) IS 'Attaches the right calc trigger to a registered table.';

-- _detach_calc_trigger
-- Removes the calc trigger from a previously registered table. Used during
-- rebuild when a table is dropped from the input list.
CREATE OR REPLACE FUNCTION claimius._detach_calc_trigger(p_object_type TEXT)
    RETURNS VOID AS $$
DECLARE
    v_parts TEXT[];
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = v_parts[1] AND table_name = v_parts[2]) THEN
        EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access ON %I.%I', v_parts[1], v_parts[2]);
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._detach_calc_trigger(TEXT) IS 'Removes calc trigger from a deregistered table.';

-- _attach_self_root_trigger
-- Attaches the appropriate self root BEFORE INSERT trigger to a registered
-- table based on its column shape. Picks one of three trigger functions:
--   has_sa_parent_id + has_sa_root_id -> _set_self_parent_on_insert
--   has_sa_root_id only               -> _set_self_root_on_insert
--   has_sa_owner_id + has_sa_root_id  -> _set_self_owner_on_insert
-- Tables without sa_root_id get no trigger (nothing to self reference).
-- Drops any existing trigger first so the operation is idempotent.
CREATE OR REPLACE FUNCTION claimius._attach_self_root_trigger(p_object_type TEXT)
    RETURNS VOID AS $$
DECLARE
    v_schema        TEXT;
    v_table         TEXT;
    v_parts         TEXT[];
    v_has_owner     BOOLEAN;
    v_has_parent    BOOLEAN;
    v_has_root      BOOLEAN;
    v_func_name     TEXT;
    v_trigger_name  TEXT := 'tg_self_root';
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    SELECT t.has_sa_owner_id, t.has_sa_parent_id, t.has_sa_root_id
    INTO v_has_owner, v_has_parent, v_has_root
    FROM claimius.table_info t WHERE t.object_type = p_object_type;

    -- No sa_root_id: nothing to self reference, skip.
    IF NOT v_has_root THEN
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_trigger_name, v_schema, v_table);
        RETURN;
    END IF;

    IF v_has_parent THEN
        -- Parenthood table: parent + root self reference together.
        v_func_name := 'claimius._set_self_parent_on_insert';
    ELSIF v_has_owner THEN
        -- Owner only (organization): owner + root self reference together.
        v_func_name := 'claimius._set_self_owner_on_insert';
    ELSE
        -- Root only (location): only root self references; parent stays NULL.
        v_func_name := 'claimius._set_self_root_on_insert';
    END IF;

    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_trigger_name, v_schema, v_table);
    EXECUTE format(
            'CREATE TRIGGER %I BEFORE INSERT ON %I.%I FOR EACH ROW EXECUTE FUNCTION %s()',
            v_trigger_name, v_schema, v_table, v_func_name
            );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._attach_self_root_trigger(TEXT) IS 'Attaches the right self root BEFORE INSERT trigger to a registered table.';

-- _detach_self_root_trigger
-- Removes the self root trigger from a previously registered table.
CREATE OR REPLACE FUNCTION claimius._detach_self_root_trigger(p_object_type TEXT)
    RETURNS VOID AS $$
DECLARE
    v_parts TEXT[];
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = v_parts[1] AND table_name = v_parts[2]) THEN
        EXECUTE format('DROP TRIGGER IF EXISTS tg_self_root ON %I.%I', v_parts[1], v_parts[2]);
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._detach_self_root_trigger(TEXT) IS 'Removes self root trigger from a deregistered table.';

-- ----------------------------------------------------------------------------
-- Calc functions: the heart of access maintenance
-- ----------------------------------------------------------------------------

-- _user_id_for_user_claim
-- Looks up the user_id for a given user_claim.id. Used to translate
-- sa_created_by into a user reference. Returns NULL if no match (which
-- happens during bootstrap before user_claims exist).
CREATE OR REPLACE FUNCTION claimius._user_id_for_user_claim(p_user_claim_id UUID)
    RETURNS TABLE(user_id UUID, app_id UUID) AS $$
BEGIN
    RETURN QUERY
        SELECT uc.user_id, uc.app_id
        FROM claimius.user_claim uc
        WHERE uc.id = p_user_claim_id AND uc.sa_deleted_at IS NULL;
END;
$$ LANGUAGE plpgsql STABLE;

-- _build_grants_for_object
-- Computes the grants jsonb array for one (user, object) pair by walking
-- claim_objects bound directly or via inheritance trees, applying deny
-- semantics. Returns an empty array if no grants survive.
CREATE OR REPLACE FUNCTION claimius._build_grants_for_object(
    p_user_id       UUID,
    p_app_id        UUID,
    p_object_type   TEXT,
    p_object_id     UUID
) RETURNS JSONB AS $$
DECLARE
    v_grants        JSONB := '[]'::JSONB;
    v_denies        JSONB := '[]'::JSONB;
    v_row           RECORD;
    v_grant_bits    INTEGER;
    v_deny_bits     INTEGER;
    v_is_deny       BOOLEAN;
BEGIN
    -- Step 1: collect every claim_object binding that could grant this user
    -- access to this object, via any path. Each row carries the claim, its
    -- bitwise access mask (which encodes the deny flag in bit 0x10), the
    -- per binding scope jsonb, and the cascaded_from anchor (the object the
    -- claim_object was bound to). For non inherited bindings, cascaded_from
    -- equals the object itself.

    FOR v_row IN
        WITH user_claims AS (
            SELECT uc.claim_id, c.sa_access AS claim_access, c.inherits, c.sa_deleted_at
            FROM claimius.user_claim uc
                     JOIN claimius.claim c ON c.id = uc.claim_id
            WHERE uc.user_id = p_user_id
              AND uc.app_id = p_app_id
              AND uc.sa_deleted_at IS NULL
              AND c.sa_deleted_at IS NULL
        ),
             direct_bindings AS (
                 -- claim_object directly on this object
                 SELECT co.claim_id,
                        p_object_type AS cascaded_from_type,
                        p_object_id   AS cascaded_from_id,
                        'direct'::TEXT AS tree_type,
                        (uc.claim_access | COALESCE(co.sa_access, uc.claim_access)) AS sa_access,
                        co.scope
                 FROM claimius.claim_object co
                          JOIN user_claims uc ON uc.claim_id = co.claim_id
                 WHERE co.object_type = p_object_type
                   AND co.object_id = p_object_id
                   AND co.app_id = p_app_id
                   AND co.sa_deleted_at IS NULL
             ),
             cascaded_bindings AS (
                 -- claim_object on an ancestor in any closure-table tree this
                 -- object participates in. Direct binding case is excluded by
                 -- depth > 0; direct_bindings handles that path.
                 SELECT co.claim_id,
                        co.object_type AS cascaded_from_type,
                        co.object_id   AS cascaded_from_id,
                        e.tree_type::TEXT AS tree_type,
                        (uc.claim_access | COALESCE(co.sa_access, uc.claim_access)) AS sa_access,
                        co.scope
                 FROM claimius.claim_object co
                          JOIN user_claims uc ON uc.claim_id = co.claim_id AND uc.inherits = TRUE
                          JOIN claimius.inheritance_info e
                              ON e.ancestor_type = co.object_type
                             AND e.ancestor_id   = co.object_id
                             AND e.descendant_type = p_object_type
                             AND e.descendant_id   = p_object_id
                             AND e.depth > 0
                 WHERE co.app_id = p_app_id
                   AND co.sa_deleted_at IS NULL
                   AND co.inherits = TRUE
             )
        SELECT * FROM direct_bindings
        UNION ALL
        SELECT * FROM cascaded_bindings
        LOOP
            v_is_deny := (v_row.sa_access & 16) <> 0;
            IF v_is_deny THEN
                v_deny_bits := v_row.sa_access & 15;
                v_denies := v_denies || jsonb_build_array(jsonb_build_object(
                        'claim_id', v_row.claim_id,
                        'access', v_deny_bits,
                        'scope', v_row.scope,
                        'cascaded_from', jsonb_build_object('type', v_row.cascaded_from_type, 'id', v_row.cascaded_from_id),
                        'tree_type', v_row.tree_type
                                                          ));
            ELSE
                v_grant_bits := v_row.sa_access & 15;
                v_grants := v_grants || jsonb_build_array(jsonb_build_object(
                        'claim_id', v_row.claim_id,
                        'access', v_grant_bits,
                        'scope', v_row.scope,
                        'cascaded_from', jsonb_build_object('type', v_row.cascaded_from_type, 'id', v_row.cascaded_from_id),
                        'tree_type', v_row.tree_type
                                                          ));
            END IF;
        END LOOP;

    -- Step 2: subtract deny bits from grants on the same path. A deny on
    -- path P with bits B clears those bits from every grant on path P.
    -- Paths are identified by (cascaded_from, tree_type). Direct denies
    -- (tree_type = 'direct', cascaded_from = the object itself) subtract
    -- bits from all grants regardless of path.
    IF jsonb_array_length(v_denies) > 0 THEN
        v_grants := claimius._apply_denies(v_grants, v_denies, p_object_type, p_object_id);
    END IF;

    RETURN v_grants;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._build_grants_for_object(p_user_id uuid, p_app_id uuid, p_object_type text, p_object_id uuid) IS 'Computes grants jsonb for a (user, object) pair, with bitwise deny subtraction.';

-- _apply_denies
-- Subtracts deny bits from each grant on the same path. Returns a new
-- jsonb array of grants. Grants whose access mask becomes 0 after
-- subtraction are dropped.
CREATE OR REPLACE FUNCTION claimius._apply_denies(
    p_grants        JSONB,
    p_denies        JSONB,
    p_object_type   TEXT,
    p_object_id     UUID
) RETURNS JSONB AS $$
DECLARE
    v_result        JSONB := '[]'::JSONB;
    v_grant         JSONB;
    v_deny          JSONB;
    v_object_key    JSONB;
    v_grant_bits    INTEGER;
    v_deny_bits     INTEGER;
BEGIN
    v_object_key := jsonb_build_object('type', p_object_type, 'id', p_object_id);

    FOR v_grant IN SELECT * FROM jsonb_array_elements(p_grants) LOOP
            v_grant_bits := (v_grant ->> 'access')::INTEGER;
            FOR v_deny IN SELECT * FROM jsonb_array_elements(p_denies) LOOP
                v_deny_bits := (v_deny ->> 'access')::INTEGER;
                -- A direct deny on the object itself subtracts from any
                -- grant on any path.
                IF (v_deny ->> 'tree_type') = 'direct' AND (v_deny -> 'cascaded_from') = v_object_key THEN
                    v_grant_bits := v_grant_bits & ~v_deny_bits;
                -- A deny on the same (tree_type, cascaded_from) path
                -- subtracts from grants on that same path.
                ELSIF (v_deny ->> 'tree_type') = (v_grant ->> 'tree_type')
                    AND (v_deny -> 'cascaded_from') = (v_grant -> 'cascaded_from') THEN
                    v_grant_bits := v_grant_bits & ~v_deny_bits;
                END IF;
                EXIT WHEN v_grant_bits = 0;
            END LOOP;
            IF v_grant_bits <> 0 THEN
                v_result := v_result || jsonb_build_array(jsonb_set(v_grant, '{access}', to_jsonb(v_grant_bits)));
            END IF;
        END LOOP;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION claimius._apply_denies(p_grants jsonb, p_denies jsonb, p_object_type text, p_object_id uuid) IS 'Subtracts deny bits from grants on matching paths. Drops grants whose mask becomes 0.';

-- _direct_grant_for_object
-- Determines whether the given user holds direct grant on the given object
-- via sa_created_by chain. A direct grant exists when there is a row in
-- the registered table with this id whose sa_created_by maps (via user_claim
-- lookup) to this user_id and app_id, AND no deny at level 0 on this object
-- blocks them.
CREATE OR REPLACE FUNCTION claimius._direct_grant_for_object(
    p_user_id       UUID,
    p_app_id        UUID,
    p_object_type   TEXT,
    p_object_id     UUID
) RETURNS BOOLEAN AS $$
DECLARE
    v_schema        TEXT;
    v_table         TEXT;
    v_parts         TEXT[];
    v_sql           TEXT;
    v_creator_uc_id UUID;
    v_creator_user  UUID;
    v_creator_app   UUID;
    v_has_deny      BOOLEAN;
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    IF p_object_type = 'claimius.samna_user' THEN
        IF NOT EXISTS (
            SELECT 1 FROM claimius.samna_user
            WHERE id = p_object_id
              AND user_id = p_user_id
              AND app_id = p_app_id
              AND sa_deleted_at IS NULL
        ) THEN
            RETURN FALSE;
        END IF;
    ELSE
        v_sql := format('SELECT sa_created_by FROM %I.%I WHERE id = $1 AND sa_deleted_at IS NULL', v_schema, v_table);
        EXECUTE v_sql INTO v_creator_uc_id USING p_object_id;

        IF v_creator_uc_id IS NULL THEN
            RETURN FALSE;
        END IF;

        IF v_creator_uc_id <> p_user_id THEN
            SELECT uc.user_id, uc.app_id INTO v_creator_user, v_creator_app
            FROM claimius.user_claim uc
            WHERE uc.id = v_creator_uc_id AND uc.sa_deleted_at IS NULL;

            IF v_creator_user IS NULL OR v_creator_user <> p_user_id OR v_creator_app <> p_app_id THEN
                RETURN FALSE;
            END IF;
        END IF;
    END IF;

    -- A direct creator's grant is wiped only by a deny that subtracts the
    -- owner bit. Any binding (claim or claim_object) whose effective mask
    -- has the deny bit (0x10) and the owner bit (0x01) on this object or
    -- any of its inherited ancestors revokes the direct grant.
    SELECT EXISTS (
        SELECT 1
        FROM claimius.user_claim uc
                 JOIN claimius.claim c ON c.id = uc.claim_id
                 JOIN claimius.claim_object co ON co.claim_id = c.id
        WHERE uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.sa_deleted_at IS NULL
          AND c.sa_deleted_at IS NULL
          AND co.app_id = p_app_id
          AND co.sa_deleted_at IS NULL
          AND ((c.sa_access | co.sa_access) & 16) <> 0
          AND ((c.sa_access | co.sa_access) & 1)  <> 0
          AND (
            (co.object_type = p_object_type AND co.object_id = p_object_id)
                OR (co.inherits = TRUE AND c.inherits = TRUE AND EXISTS (
                SELECT 1 FROM claimius.inheritance_info e
                WHERE e.ancestor_type   = co.object_type
                  AND e.ancestor_id     = co.object_id
                  AND e.descendant_type = p_object_type
                  AND e.descendant_id   = p_object_id
                  AND e.depth > 0
            ))
            )
    ) INTO v_has_deny;

    RETURN NOT v_has_deny;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._direct_grant_for_object(p_user_id uuid, p_app_id uuid, p_object_type text, p_object_id uuid) IS 'Determines if user has direct (creator) grant, accounting for owner bit denies.';

-- _denormalize_object
-- Reads the registered row's name, description, sa_owner_id, sa_location_id,
-- sa_root_id, and produces the denormalized values for user_object.
CREATE OR REPLACE FUNCTION claimius._denormalize_object(
    p_object_type   TEXT,
    p_object_id     UUID,
    OUT sa_name TEXT,
    OUT sa_description TEXT,
    OUT sa_link TEXT,
    OUT sa_owner_id UUID,
    OUT sa_location_id UUID,
    OUT sa_root_id UUID
) AS $$
DECLARE
    v_schema        TEXT;
    v_table         TEXT;
    v_parts         TEXT[];
    v_info          claimius.table_info%ROWTYPE;
    v_sql           TEXT;
    v_select_cols   TEXT;
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    SELECT * INTO v_info FROM claimius.table_info WHERE object_type = p_object_type;

    IF v_info IS NULL THEN
        RETURN;
    END IF;

    v_select_cols := format(
            '%s, %s, %s, %s, %s',
            CASE WHEN v_info.has_name THEN 'name::TEXT' ELSE 'NULL::TEXT' END,
            CASE WHEN v_info.has_description THEN 'description::TEXT' ELSE 'NULL::TEXT' END,
            CASE WHEN v_info.has_sa_owner_id THEN 'sa_owner_id' ELSE 'NULL::UUID' END,
            CASE WHEN v_info.has_sa_location_id THEN 'sa_location_id' ELSE 'NULL::UUID' END,
            CASE WHEN v_info.has_sa_root_id THEN 'sa_root_id' ELSE 'NULL::UUID' END
                     );

    v_sql := format('SELECT %s FROM %I.%I WHERE id = $1', v_select_cols, v_schema, v_table);
    EXECUTE v_sql INTO sa_name, sa_description, sa_owner_id, sa_location_id, sa_root_id USING p_object_id;

    sa_link := NULL;  -- apps may set this via update_object_metadata; left NULL by default
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._denormalize_object(p_object_type text, p_object_id uuid, OUT sa_name text, OUT sa_description text, OUT sa_link text, OUT sa_owner_id uuid, OUT sa_location_id uuid, OUT sa_root_id uuid) IS 'Reads name/description/owner/location/root from a registered row.';

-- recompute_user_object
-- The single function that recomputes the user_object row for one
-- (app_id, user_id, object_type, object_id) tuple. It handles insert,
-- update, and delete based on whether grants survive. Also maintains the
-- companion object_users and user_users rows.
CREATE OR REPLACE FUNCTION claimius.recompute_user_object(
    p_app_id        UUID,
    p_user_id       UUID,
    p_object_type   TEXT,
    p_object_id     UUID
) RETURNS VOID AS $$
DECLARE
    v_grants        JSONB;
    v_direct        BOOLEAN;
    v_id            UUID;
    v_eff_access    INTEGER;
    v_eff_scope     JSONB;
    v_grant_obj     JSONB;
    v_any_unbounded BOOLEAN;
    v_norm          RECORD;
    v_search_vec    TSVECTOR;
BEGIN
    v_id := claimius.composite_id(p_app_id::TEXT, p_user_id::TEXT, p_object_type, p_object_id::TEXT);

    v_grants := claimius._build_grants_for_object(p_user_id, p_app_id, p_object_type, p_object_id);
    v_direct := claimius._direct_grant_for_object(p_user_id, p_app_id, p_object_type, p_object_id);

    -- No surviving access at all: delete the user_object row and companions
    IF jsonb_array_length(v_grants) = 0 AND NOT v_direct THEN
        DELETE FROM claimius.user_object WHERE id = v_id;
        DELETE FROM claimius.object_users
        WHERE app_id = p_app_id AND object_id = p_object_id
          AND object_type = p_object_type AND user_id = p_user_id;
        PERFORM claimius._refresh_user_users(p_app_id, p_user_id);
        RETURN;
    END IF;

    -- Effective access mask: bitwise OR over all surviving grants. Direct
    -- creator contributes the full operator mask (owner | write | read |
    -- execute). Deny semantics already applied in _build_grants_for_object.
    IF v_direct THEN
        v_eff_access := 15;
    ELSE
        v_eff_access := 0;
    END IF;
    FOR v_grant_obj IN SELECT * FROM jsonb_array_elements(v_grants) LOOP
        v_eff_access := v_eff_access | (v_grant_obj ->> 'access')::INTEGER;
    END LOOP;

    -- Effective scope: any grant without a scope grants the whole object,
    -- so the merged scope is NULL. Otherwise union the keys of every
    -- grant's scope object.
    v_any_unbounded := v_direct;
    v_eff_scope := NULL;
    IF NOT v_any_unbounded THEN
        FOR v_grant_obj IN SELECT * FROM jsonb_array_elements(v_grants) LOOP
            IF (v_grant_obj -> 'scope') IS NULL OR jsonb_typeof(v_grant_obj -> 'scope') = 'null' THEN
                v_any_unbounded := TRUE;
                EXIT;
            END IF;
        END LOOP;
    END IF;
    IF NOT v_any_unbounded THEN
        v_eff_scope := '{}'::jsonb;
        FOR v_grant_obj IN SELECT * FROM jsonb_array_elements(v_grants) LOOP
            v_eff_scope := v_eff_scope || coalesce(v_grant_obj -> 'scope', '{}'::jsonb);
        END LOOP;
    END IF;

    -- Pull denormalized fields
    SELECT * INTO v_norm FROM claimius._denormalize_object(p_object_type, p_object_id);

    v_search_vec :=
            setweight(to_tsvector('simple', coalesce(v_norm.sa_name, '')), 'A') ||
            setweight(to_tsvector('simple', coalesce(v_norm.sa_description, '')), 'B');

    INSERT INTO claimius.user_object (
        id, app_id, user_id, object_id, object_type,
        sa_access, scope, grants, direct_grant,
        sa_owner_id, sa_location_id, sa_root_id,
        sa_name, sa_description, sa_link, search_vector
    ) VALUES (
                 v_id, p_app_id, p_user_id, p_object_id, p_object_type,
                 v_eff_access, v_eff_scope, v_grants, v_direct,
                 v_norm.sa_owner_id, v_norm.sa_location_id, v_norm.sa_root_id,
                 v_norm.sa_name, v_norm.sa_description, v_norm.sa_link, v_search_vec
             )
    ON CONFLICT (id) DO UPDATE SET
                                   sa_access = EXCLUDED.sa_access,
                                   scope = EXCLUDED.scope,
                                   grants = EXCLUDED.grants,
                                   direct_grant = EXCLUDED.direct_grant,
                                   sa_owner_id = EXCLUDED.sa_owner_id,
                                   sa_location_id = EXCLUDED.sa_location_id,
                                   sa_root_id = EXCLUDED.sa_root_id,
                                   sa_name = EXCLUDED.sa_name,
                                   sa_description = EXCLUDED.sa_description,
                                   sa_link = EXCLUDED.sa_link,
                                   search_vector = EXCLUDED.search_vector,
                                   sa_updated_at = now();

    -- Maintain object_users
    INSERT INTO claimius.object_users (id, app_id, object_id, object_type, user_id)
    VALUES (
               claimius.composite_id(p_app_id::TEXT, p_object_type, p_object_id::TEXT, p_user_id::TEXT),
               p_app_id, p_object_id, p_object_type, p_user_id
           )
    ON CONFLICT (id) DO UPDATE SET sa_updated_at = now();

    PERFORM claimius._refresh_user_users(p_app_id, p_user_id);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.recompute_user_object(p_app_id uuid, p_user_id uuid, p_object_type text, p_object_id uuid) IS 'Recomputes user_object plus companions for one (app, user, object) tuple.';

-- _refresh_user_users
-- Recomputes user_users entries for one (app_id, viewer) pair from
-- object_users.
CREATE OR REPLACE FUNCTION claimius._refresh_user_users(p_app_id UUID, p_viewer_id UUID)
    RETURNS VOID AS $$
BEGIN
    -- Remove existing rows for this viewer
    DELETE FROM claimius.user_users
    WHERE app_id = p_app_id AND viewer_id = p_viewer_id;

    -- Insert one row per other user the viewer shares any object with
    INSERT INTO claimius.user_users (id, app_id, viewer_id, target_user_id, sharing_object_count, first_shared_at, last_shared_at)
    SELECT
        claimius.composite_id(p_app_id::TEXT, p_viewer_id::TEXT, target.user_id::TEXT),
        p_app_id,
        p_viewer_id,
        target.user_id,
        count(*),
        min(target.sa_created_at),
        max(target.sa_updated_at)
    FROM claimius.object_users viewer
             JOIN claimius.object_users target
                  ON target.app_id = viewer.app_id
                      AND target.object_id = viewer.object_id
                      AND target.object_type = viewer.object_type
                      AND target.user_id <> viewer.user_id
    WHERE viewer.app_id = p_app_id AND viewer.user_id = p_viewer_id
    GROUP BY target.user_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._refresh_user_users(p_app_id uuid, p_viewer_id uuid) IS 'Rebuilds user_users rows for one (app, viewer).';

-- _affected_users_for_object
-- Returns the list of users whose access to the given object could change.
-- Includes any user holding a relevant claim plus any user already in
-- object_users for that object.
CREATE OR REPLACE FUNCTION claimius._affected_users_for_object(
    p_app_id        UUID,
    p_object_type   TEXT,
    p_object_id     UUID
) RETURNS TABLE(user_id UUID) AS $$
BEGIN
    RETURN QUERY
        WITH all_users AS (
            -- existing object_users
            SELECT ou.user_id FROM claimius.object_users ou
            WHERE ou.app_id = p_app_id AND ou.object_id = p_object_id AND ou.object_type = p_object_type

            UNION

            -- users holding any user_claim in this app whose claim is bound
            -- directly to this object
            SELECT uc.user_id
            FROM claimius.user_claim uc
                     JOIN claimius.claim_object co
                          ON co.claim_id = uc.claim_id
                         AND co.app_id = p_app_id
                         AND co.sa_deleted_at IS NULL
                         AND co.object_type = p_object_type
                         AND co.object_id = p_object_id
            WHERE uc.app_id = p_app_id
              AND uc.sa_deleted_at IS NULL

            UNION

            -- users holding any user_claim whose claim is bound to an ancestor
            -- of this object via the closure index
            SELECT uc.user_id
            FROM claimius.user_claim uc
                     JOIN claimius.claim_object co
                          ON co.claim_id = uc.claim_id
                         AND co.app_id = p_app_id
                         AND co.sa_deleted_at IS NULL
                         AND co.inherits = TRUE
                     JOIN claimius.inheritance_info e
                          ON e.ancestor_type   = co.object_type
                         AND e.ancestor_id     = co.object_id
                         AND e.descendant_type = p_object_type
                         AND e.descendant_id   = p_object_id
                         AND e.depth > 0
            WHERE uc.app_id = p_app_id
              AND uc.sa_deleted_at IS NULL
        )
        SELECT DISTINCT au.user_id FROM all_users au;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION claimius._affected_users_for_object(p_app_id uuid, p_object_type text, p_object_id uuid) IS 'Users whose access to the object could change.';

-- ============================================================================
-- Ancestor walks
-- ============================================================================
-- Three helpers walk an object's structural ancestors. Each returns rows
-- shaped (object_type TEXT, object_id UUID, hop INTEGER) with hop = 0 for
-- the object itself, hop = 1 for its direct parent in that tree, etc.
-- get_ancestors combines all three and tags each row with the tree_type.

-- get_owner_ancestors
-- Reads the ownership tree closure for ancestors of (p_object_type, p_object_id).
-- Returns the object itself at hop 0 (closure self-edge) plus every ancestor
-- with depth as hop.
CREATE OR REPLACE FUNCTION claimius.get_owner_ancestors(
    p_object_type TEXT,
    p_object_id   UUID
) RETURNS TABLE(object_type TEXT, object_id UUID, hop INTEGER) AS $$
BEGIN
    RETURN QUERY
        SELECT e.ancestor_type, e.ancestor_id, e.depth
        FROM claimius.inheritance_info e
        WHERE e.tree_type = 'ownership'
          AND e.descendant_type = p_object_type
          AND e.descendant_id   = p_object_id
        ORDER BY e.depth;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION claimius.get_owner_ancestors(p_object_type text, p_object_id uuid) IS 'Ownership tree ancestors of an object, hop 0 = self.';

-- get_location_ancestors
-- Reads the location tree closure for location ancestors of an object, plus
-- the owning org chain of each location encountered (so a claim on a parent
-- org of a location grants access via the location too).
CREATE OR REPLACE FUNCTION claimius.get_location_ancestors(
    p_object_type TEXT,
    p_object_id   UUID
) RETURNS TABLE(object_type TEXT, object_id UUID, hop INTEGER) AS $$
BEGIN
    -- Location chain (self-edge included if p_object IS a location).
    RETURN QUERY
        SELECT e.ancestor_type, e.ancestor_id, e.depth
        FROM claimius.inheritance_info e
        WHERE e.tree_type = 'location'
          AND e.descendant_type = p_object_type
          AND e.descendant_id   = p_object_id
          AND e.ancestor_type   = 'claimius.location';

    -- For non-locations, emit self at hop 0 (location closure has no row for
    -- the object itself when the object is not a location).
    IF p_object_type <> 'claimius.location' THEN
        RETURN QUERY SELECT p_object_type, p_object_id, 0;
    END IF;

    -- For each location in the chain, expand to its owning org chain. Hop
    -- offsets: location's own depth, plus 1 for the owning org, plus the
    -- ownership-chain depth of that org.
    RETURN QUERY
        WITH loc_chain AS (
            SELECT e.ancestor_id AS loc_id, e.depth AS loc_depth
            FROM claimius.inheritance_info e
            WHERE e.tree_type = 'location'
              AND e.descendant_type = p_object_type
              AND e.descendant_id   = p_object_id
              AND e.ancestor_type   = 'claimius.location'
        )
        SELECT 'claimius.organization'::TEXT, eo.ancestor_id, lc.loc_depth + 1 + eo.depth
        FROM loc_chain lc
                 JOIN claimius.location l
                      ON l.id = lc.loc_id AND l.sa_deleted_at IS NULL
                 JOIN claimius.inheritance_info eo
                      ON eo.tree_type = 'ownership'
                     AND eo.descendant_type = 'claimius.organization'
                     AND eo.descendant_id   = l.sa_owner_id
        WHERE l.sa_owner_id IS NOT NULL;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION claimius.get_location_ancestors(p_object_type text, p_object_id uuid) IS 'Location chain ancestors of an object plus each location''s owning org chain.';

-- get_parenthood_ancestors
-- Reads the parenthood tree closure for ancestors of an object whose table
-- is self referencing via sa_parent_id.
CREATE OR REPLACE FUNCTION claimius.get_parenthood_ancestors(
    p_object_type TEXT,
    p_object_id   UUID
) RETURNS TABLE(object_type TEXT, object_id UUID, hop INTEGER) AS $$
BEGIN
    RETURN QUERY
        SELECT e.ancestor_type, e.ancestor_id, e.depth
        FROM claimius.inheritance_info e
        WHERE e.tree_type = 'parenthood'
          AND e.descendant_type = p_object_type
          AND e.descendant_id   = p_object_id
        ORDER BY e.depth;

    -- For tables that participate in no parenthood tree, the closure has no
    -- self-edge for this row. Emit self at hop 0 so callers always see it.
    IF NOT EXISTS (
        SELECT 1 FROM claimius.inheritance_info e
        WHERE e.tree_type = 'parenthood'
          AND e.descendant_type = p_object_type
          AND e.descendant_id   = p_object_id
          AND e.depth = 0
    ) THEN
        RETURN QUERY SELECT p_object_type, p_object_id, 0;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION claimius.get_parenthood_ancestors(p_object_type text, p_object_id uuid) IS 'Parenthood tree ancestors via sa_parent_id, hop 0 = self.';

-- get_ancestors
-- Combined ancestor walk. Yields rows from the owner, location, and
-- parenthood trees, tagged with tree_type. Hops are independent per tree;
-- the same object may appear in multiple trees with different hops.
CREATE OR REPLACE FUNCTION claimius.get_ancestors(
    p_object_type TEXT,
    p_object_id   UUID
) RETURNS TABLE(object_type TEXT, object_id UUID, hop INTEGER, tree_type TEXT) AS $$
BEGIN
    RETURN QUERY
        SELECT a.object_type, a.object_id, a.hop, 'ownership'::TEXT
        FROM claimius.get_owner_ancestors(p_object_type, p_object_id) a;

    RETURN QUERY
        SELECT a.object_type, a.object_id, a.hop, 'location'::TEXT
        FROM claimius.get_location_ancestors(p_object_type, p_object_id) a;

    RETURN QUERY
        SELECT a.object_type, a.object_id, a.hop, 'parenthood'::TEXT
        FROM claimius.get_parenthood_ancestors(p_object_type, p_object_id) a;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION claimius.get_ancestors(p_object_type text, p_object_id uuid) IS 'Combined ancestor walk across owner, location, and parenthood trees.';