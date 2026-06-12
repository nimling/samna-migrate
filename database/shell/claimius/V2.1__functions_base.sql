-- ============================================================================
-- Claimius V2.1 Base Functions
-- ----------------------------------------------------------------------------
-- The innermost utility functions. These have no dependencies on other
-- claimius functions and are called by everything else.
-- ============================================================================

-- composite_id
-- Hashes the joined input parts into a deterministic UUID. Same inputs
-- produce the same id on every node, so prophet and disciple converge on
-- the same row identity without coordinating writes. Used for the row id
-- of materialization tables (user_object, object_users, user_users,
-- reconcile_queue) and for the cascaded_from anchor key inside grants
-- jsonb where two parts (object_type, object_id) collapse into a single
-- comparable identifier.
CREATE OR REPLACE FUNCTION claimius.composite_id(VARIADIC parts TEXT[])
    RETURNS UUID AS $$
SELECT md5(array_to_string(parts, ':'))::UUID;
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION claimius.composite_id(TEXT[]) IS 'Deterministic UUID hash of the joined parts. Same inputs always produce same id.';

-- split_object_type
-- Splits a schema-qualified table name like 'claimius.samna_app' into
-- ['claimius', 'samna_app']. If unqualified, returns ['public', name].
-- This is for object_type strings (schema.table). For composite ids
-- (object_type:uuid), use decompose_id.
CREATE OR REPLACE FUNCTION claimius.split_object_type(p_object_type TEXT)
    RETURNS TEXT[] AS $$
SELECT CASE
           WHEN position('.' IN p_object_type) = 0 THEN ARRAY['public', p_object_type]
           ELSE ARRAY[split_part(p_object_type, '.', 1), split_part(p_object_type, '.', 2)]
           END;
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION claimius.split_object_type(TEXT) IS 'Splits a schema.table string into [schema, table]. Defaults to public schema.';

-- update_timestamp
-- Trigger function that sets sa_updated_at to now() on every UPDATE.
CREATE OR REPLACE FUNCTION claimius.update_timestamp()
    RETURNS TRIGGER AS $$
BEGIN
    NEW.sa_updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.update_timestamp() IS 'Trigger function. Sets sa_updated_at = now() on UPDATE.';

-- get_table_columns
-- Returns the column names for a (schema qualified) table.
CREATE OR REPLACE FUNCTION claimius.get_table_columns(p_object_type TEXT)
    RETURNS TABLE(column_name TEXT) AS $$
DECLARE
    v_schema TEXT;
    v_table TEXT;
    v_parts TEXT[];
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];
    RETURN QUERY
        SELECT c.column_name::TEXT
        FROM information_schema.columns c
        WHERE c.table_schema = v_schema AND c.table_name = v_table;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION claimius.get_table_columns(TEXT) IS 'Returns column names for a schema qualified table.';

-- table_has_column
-- Helper that returns true if the given object_type has the given column.
CREATE OR REPLACE FUNCTION claimius.table_has_column(p_object_type TEXT, p_column TEXT)
    RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM claimius.get_table_columns(p_object_type) WHERE column_name = p_column
    );
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION claimius.table_has_column(TEXT, TEXT) IS 'True if the given table has the given column.';

-- ensure_uuid_null
-- Defensive helper for callers that may emit the zero UUID instead of SQL
-- NULL. Returns NULL for both NULL and the all zero UUID; passes any real
-- UUID through unchanged. Applied at the top of public functions that
-- accept an optional UUID parameter so the wire shape "value or NULL" is
-- honored even when a caller serializes a zero UUID literal.
CREATE OR REPLACE FUNCTION claimius.ensure_uuid_null(p UUID) RETURNS UUID
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT NULLIF(p, '00000000-0000-0000-0000-000000000000'::uuid);
$$;

COMMENT ON FUNCTION claimius.ensure_uuid_null IS 'Returns NULL when input is NULL or the zero UUID; otherwise the UUID unchanged.';

-- write_audit
-- Inserts a row into claimius.audit. Used by audit triggers and by error
-- paths inside other triggers.
-- p_sa_created_by may be NULL for events with no clear actor (system
-- triggers, replay, denied access attempts).
DROP FUNCTION IF EXISTS claimius.write_audit(UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, TEXT);

CREATE OR REPLACE FUNCTION claimius.write_audit(
    p_app_id        UUID,
    p_operation     TEXT,
    p_type          TEXT,
    p_object_type   TEXT,
    p_object_id     UUID,
    p_sa_owner_id   UUID,
    p_sa_created_by UUID DEFAULT NULL,
    p_message       TEXT DEFAULT ''
) RETURNS claimius.audit AS $$
DECLARE
    v_row claimius.audit;
BEGIN
    INSERT INTO claimius.audit (
        app_id, operation, type, object_type, object_id,
        sa_owner_id, sa_created_by, message
    ) VALUES (
                 p_app_id, p_operation, p_type, p_object_type, p_object_id,
                 p_sa_owner_id, p_sa_created_by, p_message
             )
    RETURNING * INTO v_row;
    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.write_audit IS 'Inserts a row into the audit log and returns it.';

-- in_replay_mode
-- Returns true if claimius.replay_mode is set on this session. Used by
-- triggers to short circuit during disciple replay.
CREATE OR REPLACE FUNCTION claimius.in_replay_mode()
    RETURNS BOOLEAN AS $$
BEGIN
    RETURN coalesce(current_setting('claimius.replay_mode', TRUE), 'false') = 'true';
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION claimius.in_replay_mode() IS 'True when claimius.replay_mode session GUC is "true". Triggers short circuit.';

-- get_subtree
-- Returns (object_type, object_id) descendants under a starting node in the
-- named tree, reading the closure index. The self-edge (depth = 0) means the
-- start node itself is included in the returned set.
CREATE OR REPLACE FUNCTION claimius.get_subtree(
    p_tree_type     claimius.tree_type,
    p_root_id       UUID,
    p_start_type    TEXT,
    p_start_id      UUID
) RETURNS TABLE(object_type TEXT, object_id UUID) AS $$
BEGIN
    RETURN QUERY
        SELECT i.descendant_type, i.descendant_id
        FROM claimius.inheritance_info i
        WHERE i.tree_type = p_tree_type
          AND i.root_id = p_root_id
          AND i.ancestor_type = p_start_type
          AND i.ancestor_id = p_start_id;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION claimius.get_subtree IS 'Returns (object_type, object_id) descendants under a start node in a tree, self-edge included.';

-- _popcount
-- Counts the number of bits set in an integer access mask. Used to rank
-- grants whose mask covers the required access bits, so callers can pick
-- the strongest grant when several survive.
CREATE OR REPLACE FUNCTION claimius._popcount(p INTEGER)
    RETURNS INTEGER AS $$
DECLARE
    v INTEGER := coalesce(p, 0);
    n INTEGER := 0;
BEGIN
    WHILE v <> 0 LOOP
        v := v & (v - 1);
        n := n + 1;
    END LOOP;
    RETURN n;
END;
$$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

COMMENT ON FUNCTION claimius._popcount(INTEGER) IS 'Bit count of an integer access mask. Used for ranking grants.';