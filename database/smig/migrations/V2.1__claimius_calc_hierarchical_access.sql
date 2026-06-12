CREATE OR REPLACE FUNCTION claimius.apply_row_delta(
    p_object_type TEXT,
    p_object_id   UUID,
    p_old         JSONB,
    p_new         JSONB
) RETURNS VOID AS $$
DECLARE
    v_old_active BOOLEAN := (p_old IS NOT NULL AND (p_old ->> 'sa_deleted_at') IS NULL);
    v_new_active BOOLEAN := (p_new IS NOT NULL AND (p_new ->> 'sa_deleted_at') IS NULL);
    v_owner_id   UUID;
    v_loc_id     UUID;
    v_parent_id  UUID;
    v_root_id    UUID;
    v_info       claimius.table_info%ROWTYPE;
BEGIN
    SELECT * INTO v_info FROM claimius.table_info WHERE object_type = p_object_type;

    IF v_old_active THEN
        DELETE FROM claimius.inheritance_info
        WHERE descendant_type = p_object_type AND descendant_id = p_object_id;
    END IF;

    IF NOT v_new_active THEN
        RETURN;
    END IF;

    v_owner_id  := (p_new ->> 'sa_owner_id')::UUID;
    v_loc_id    := (p_new ->> 'sa_location_id')::UUID;
    v_parent_id := (p_new ->> 'sa_parent_id')::UUID;
    v_root_id   := (p_new ->> 'sa_root_id')::UUID;

    IF p_object_type = 'claimius.organization' THEN
        INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
        VALUES ('ownership', v_root_id, p_object_type, p_object_id, p_object_type, p_object_id, 0)
        ON CONFLICT DO NOTHING;

        IF v_owner_id IS NOT NULL AND v_owner_id <> p_object_id THEN
            INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
            SELECT e.tree_type, e.root_id, e.ancestor_type, e.ancestor_id, p_object_type, p_object_id, e.depth + 1
            FROM claimius.inheritance_info e
            WHERE e.tree_type = 'ownership'
              AND e.descendant_type = 'claimius.organization'
              AND e.descendant_id = v_owner_id
            ON CONFLICT DO NOTHING;
        END IF;
        RETURN;
    END IF;

    IF p_object_type = 'claimius.location' THEN
        INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
        VALUES ('location', v_root_id, p_object_type, p_object_id, p_object_type, p_object_id, 0)
        ON CONFLICT DO NOTHING;

        IF v_parent_id IS NOT NULL AND v_parent_id <> p_object_id THEN
            INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
            SELECT e.tree_type, e.root_id, e.ancestor_type, e.ancestor_id, p_object_type, p_object_id, e.depth + 1
            FROM claimius.inheritance_info e
            WHERE e.tree_type = 'location'
              AND e.descendant_type = 'claimius.location'
              AND e.descendant_id = v_parent_id
            ON CONFLICT DO NOTHING;
        END IF;

        IF v_owner_id IS NOT NULL THEN
            INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
            SELECT 'ownership'::claimius.tree_type, e.root_id, p_object_type, p_object_id, p_object_type, p_object_id, 0
            FROM claimius.inheritance_info e
            WHERE e.tree_type = 'ownership'
              AND e.descendant_type = 'claimius.organization'
              AND e.descendant_id = v_owner_id
              AND e.depth = 0
            ON CONFLICT DO NOTHING;

            INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
            SELECT e.tree_type, e.root_id, e.ancestor_type, e.ancestor_id, p_object_type, p_object_id, e.depth + 1
            FROM claimius.inheritance_info e
            WHERE e.tree_type = 'ownership'
              AND e.descendant_type = 'claimius.organization'
              AND e.descendant_id = v_owner_id
            ON CONFLICT DO NOTHING;
        END IF;
        RETURN;
    END IF;

    IF v_info.has_sa_owner_id AND v_owner_id IS NOT NULL THEN
        INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
        SELECT 'ownership'::claimius.tree_type, e.root_id, p_object_type, p_object_id, p_object_type, p_object_id, 0
        FROM claimius.inheritance_info e
        WHERE e.tree_type = 'ownership'
          AND e.descendant_type = 'claimius.organization'
          AND e.descendant_id = v_owner_id
          AND e.depth = 0
        ON CONFLICT DO NOTHING;

        INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
        SELECT 'ownership'::claimius.tree_type, e.root_id, e.ancestor_type, e.ancestor_id, p_object_type, p_object_id, e.depth + 1
        FROM claimius.inheritance_info e
        WHERE e.tree_type = 'ownership'
          AND e.descendant_type = 'claimius.organization'
          AND e.descendant_id = v_owner_id
        ON CONFLICT DO NOTHING;
    END IF;

    IF v_info.has_sa_location_id AND v_loc_id IS NOT NULL THEN
        INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
        SELECT 'location'::claimius.tree_type, e.root_id, p_object_type, p_object_id, p_object_type, p_object_id, 0
        FROM claimius.inheritance_info e
        WHERE e.tree_type = 'location'
          AND e.descendant_type = 'claimius.location'
          AND e.descendant_id = v_loc_id
          AND e.depth = 0
        ON CONFLICT DO NOTHING;

        INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
        SELECT 'location'::claimius.tree_type, e.root_id, e.ancestor_type, e.ancestor_id, p_object_type, p_object_id, e.depth + 1
        FROM claimius.inheritance_info e
        WHERE e.tree_type = 'location'
          AND e.descendant_type = 'claimius.location'
          AND e.descendant_id = v_loc_id
        ON CONFLICT DO NOTHING;
    END IF;

    IF v_info.has_sa_parent_id AND v_info.has_sa_root_id THEN
        INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
        VALUES ('parenthood', v_root_id, p_object_type, p_object_id, p_object_type, p_object_id, 0)
        ON CONFLICT DO NOTHING;

        IF v_parent_id IS NOT NULL AND v_parent_id <> p_object_id THEN
            INSERT INTO claimius.inheritance_info (tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth)
            SELECT e.tree_type, e.root_id, e.ancestor_type, e.ancestor_id, p_object_type, p_object_id, e.depth + 1
            FROM claimius.inheritance_info e
            WHERE e.tree_type = 'parenthood'
              AND e.descendant_type = p_object_type
              AND e.descendant_id = v_parent_id
            ON CONFLICT DO NOTHING;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.apply_row_delta(TEXT, UUID, JSONB, JSONB) IS 'Per row writer to claimius.inheritance_info. Reads claimius.get_ancestors via the closure to mirror parent edges. Used by triggers and rebuild_tree.';


CREATE OR REPLACE FUNCTION claimius.rebuild_tree(p_root_id UUID)
    RETURNS VOID AS $$
DECLARE
    v_row RECORD;
    v_info claimius.table_info%ROWTYPE;
    v_conds TEXT;
BEGIN
    DELETE FROM claimius.inheritance_info WHERE root_id = p_root_id;

    FOR v_row IN
        WITH RECURSIVE org_chain AS (
            SELECT o.id, o.sa_owner_id, 0 AS depth, to_jsonb(o) AS row_data
            FROM claimius.organization o
            WHERE o.id = p_root_id AND o.sa_deleted_at IS NULL
            UNION ALL
            SELECT o.id, o.sa_owner_id, oc.depth + 1, to_jsonb(o)
            FROM claimius.organization o
                     JOIN org_chain oc ON o.sa_owner_id = oc.id
            WHERE o.id <> o.sa_owner_id AND o.sa_deleted_at IS NULL
        )
        SELECT id, row_data FROM org_chain ORDER BY depth
    LOOP
        PERFORM claimius.apply_row_delta('claimius.organization', v_row.id, NULL::JSONB, v_row.row_data);
    END LOOP;

    FOR v_row IN
        WITH RECURSIVE loc_chain AS (
            SELECT l.id, l.sa_parent_id, l.sa_owner_id, 0 AS depth, to_jsonb(l) AS row_data
            FROM claimius.location l
            WHERE l.sa_root_id = p_root_id AND l.sa_parent_id = l.id AND l.sa_deleted_at IS NULL
            UNION ALL
            SELECT l.id, l.sa_parent_id, l.sa_owner_id, lc.depth + 1, to_jsonb(l)
            FROM claimius.location l
                     JOIN loc_chain lc ON l.sa_parent_id = lc.id
            WHERE l.id <> l.sa_parent_id AND l.sa_deleted_at IS NULL AND l.sa_root_id = p_root_id
        )
        SELECT id, row_data FROM loc_chain ORDER BY depth
    LOOP
        PERFORM claimius.apply_row_delta('claimius.location', v_row.id, NULL::JSONB, v_row.row_data);
    END LOOP;

    FOR v_info IN
        SELECT * FROM claimius.table_info
        WHERE object_type NOT IN ('claimius.organization', 'claimius.location')
          AND has_sa_deleted_at
    LOOP
        IF v_info.has_sa_parent_id AND v_info.has_sa_root_id THEN
            FOR v_row IN EXECUTE format(
                $f$
                WITH RECURSIVE chain AS (
                    SELECT id, sa_parent_id, 0 AS depth
                    FROM %1$I.%2$I
                    WHERE sa_root_id = $1 AND sa_parent_id = id AND sa_deleted_at IS NULL
                    UNION ALL
                    SELECT r.id, r.sa_parent_id, c.depth + 1
                    FROM %1$I.%2$I r
                             JOIN chain c ON r.sa_parent_id = c.id
                    WHERE r.id <> r.sa_parent_id AND r.sa_deleted_at IS NULL AND r.sa_root_id = $1
                )
                SELECT id FROM chain ORDER BY depth
                $f$,
                split_part(v_info.object_type, '.', 1),
                split_part(v_info.object_type, '.', 2)
            ) USING p_root_id
            LOOP
                EXECUTE format(
                    'SELECT claimius.apply_row_delta($1, $2, NULL::JSONB, to_jsonb(r.*)) FROM %1$I.%2$I r WHERE r.id = $2',
                    split_part(v_info.object_type, '.', 1),
                    split_part(v_info.object_type, '.', 2)
                ) USING v_info.object_type, v_row.id;
            END LOOP;
        ELSE
            v_conds := NULL;
            IF v_info.has_sa_owner_id THEN
                v_conds := 'sa_owner_id IN (SELECT descendant_id FROM claimius.inheritance_info WHERE tree_type = ''ownership'' AND root_id = $1 AND descendant_type = ''claimius.organization'')';
            END IF;
            IF v_info.has_sa_location_id THEN
                v_conds := CASE WHEN v_conds IS NULL THEN '' ELSE v_conds || ' OR ' END
                    || 'sa_location_id IN (SELECT descendant_id FROM claimius.inheritance_info WHERE tree_type = ''location'' AND root_id = $1 AND descendant_type = ''claimius.location'')';
            END IF;
            IF v_conds IS NULL THEN
                CONTINUE;
            END IF;
            FOR v_row IN EXECUTE format(
                'SELECT id FROM %1$I.%2$I WHERE sa_deleted_at IS NULL AND (%3$s)',
                split_part(v_info.object_type, '.', 1),
                split_part(v_info.object_type, '.', 2),
                v_conds
            ) USING p_root_id
            LOOP
                EXECUTE format(
                    'SELECT claimius.apply_row_delta($1, $2, NULL::JSONB, to_jsonb(r.*)) FROM %1$I.%2$I r WHERE r.id = $2',
                    split_part(v_info.object_type, '.', 1),
                    split_part(v_info.object_type, '.', 2)
                ) USING v_info.object_type, v_row.id;
            END LOOP;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.rebuild_tree(UUID) IS 'Drives apply_row_delta over every structural row under p_root_id in parent first topological order. Used at init, replay, and repair.';


CREATE OR REPLACE FUNCTION claimius.rebuild_user_object()
    RETURNS VOID AS $$
DECLARE
    v_pair RECORD;
BEGIN
    DELETE FROM claimius.user_object;

    FOR v_pair IN
        SELECT DISTINCT uc.app_id, uc.user_id, co.object_type, co.object_id
        FROM claimius.user_claim uc
                 JOIN claimius.claim_object co ON co.claim_id = uc.claim_id
        WHERE uc.sa_deleted_at IS NULL
          AND co.sa_deleted_at IS NULL
    LOOP
        PERFORM claimius.recompute_user_object(v_pair.app_id, v_pair.user_id, v_pair.object_type, v_pair.object_id);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.rebuild_user_object() IS 'Wipes and reseeds claimius.user_object from current claims. Admin and repair tool.';


CREATE OR REPLACE FUNCTION claimius.calc_hierarchical_access()
    RETURNS TRIGGER AS $$
DECLARE
    v_object_type TEXT;
    v_row RECORD;
    v_app_id UUID;
    v_old_jsonb JSONB;
    v_new_jsonb JSONB;
    v_dirty_id UUID;
BEGIN
    IF claimius.in_replay_mode() THEN
        RETURN NULL;
    END IF;

    v_object_type := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;

    IF TG_OP = 'UPDATE' THEN
        FOR v_row IN
            SELECT
                (new_rows.row_data ->> 'sa_root_id')::UUID AS new_root,
                (old_rows.row_data ->> 'sa_root_id')::UUID AS old_root,
                new_rows.row_data ->> 'id' AS rid
            FROM (SELECT to_jsonb(r) AS row_data FROM new_rows r) new_rows
                     JOIN (SELECT to_jsonb(r) AS row_data FROM old_rows r) old_rows
                          ON new_rows.row_data ->> 'id' = old_rows.row_data ->> 'id'
            WHERE (new_rows.row_data ->> 'sa_root_id') IS DISTINCT FROM (old_rows.row_data ->> 'sa_root_id')
        LOOP
            RAISE EXCEPTION 'Cross root reparenting is not allowed. Use migrate_root() if absolutely required.';
        END LOOP;
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        FOR v_row IN SELECT to_jsonb(r) AS row_data FROM new_rows r LOOP
            v_dirty_id := (v_row.row_data ->> 'id')::UUID;
            v_new_jsonb := v_row.row_data;
            v_old_jsonb := NULL;
            IF TG_OP = 'UPDATE' THEN
                SELECT to_jsonb(r) INTO v_old_jsonb FROM old_rows r WHERE (to_jsonb(r) ->> 'id')::UUID = v_dirty_id;
            END IF;
            v_app_id := claimius._app_id_for_row(v_object_type, v_new_jsonb);
            PERFORM claimius.apply_row_delta(v_object_type, v_dirty_id, v_old_jsonb, v_new_jsonb);
            PERFORM claimius.recompute_user_object(v_app_id, u.user_id, v_object_type, v_dirty_id)
            FROM claimius._affected_users_for_object(v_app_id, v_object_type, v_dirty_id) u;
        END LOOP;
    END IF;

    IF TG_OP IN ('DELETE', 'UPDATE') THEN
        FOR v_row IN SELECT to_jsonb(r) AS row_data FROM old_rows r LOOP
            v_dirty_id := (v_row.row_data ->> 'id')::UUID;
            IF TG_OP = 'DELETE' THEN
                v_old_jsonb := v_row.row_data;
                v_new_jsonb := NULL;
                v_app_id := claimius._app_id_for_row(v_object_type, v_old_jsonb);
                PERFORM claimius.apply_row_delta(v_object_type, v_dirty_id, v_old_jsonb, v_new_jsonb);
                PERFORM claimius.recompute_user_object(v_app_id, u.user_id, v_object_type, v_dirty_id)
                FROM claimius._affected_users_for_object(v_app_id, v_object_type, v_dirty_id) u;
            END IF;
        END LOOP;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.calc_hierarchical_access() IS 'Statement level trigger on hierarchical tables. Calls apply_row_delta per dirty row and recomputes user_object for affected users.';


DO $$
DECLARE
    v_table claimius.table_info%ROWTYPE;
    v_schema TEXT;
    v_name TEXT;
BEGIN
    FOR v_table IN
        SELECT * FROM claimius.table_info
        WHERE object_type IN ('claimius.organization', 'claimius.location')
           OR (has_sa_parent_id AND has_sa_root_id)
    LOOP
        v_schema := split_part(v_table.object_type, '.', 1);
        v_name := split_part(v_table.object_type, '.', 2);
        EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access ON %I.%I', v_schema, v_name);
        EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access_insert ON %I.%I', v_schema, v_name);
        EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access_update ON %I.%I', v_schema, v_name);
        EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access_delete ON %I.%I', v_schema, v_name);
        EXECUTE format('CREATE TRIGGER tg_calc_access_insert AFTER INSERT ON %I.%I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION claimius.calc_hierarchical_access()', v_schema, v_name);
        EXECUTE format('CREATE TRIGGER tg_calc_access_update AFTER UPDATE ON %I.%I REFERENCING NEW TABLE AS new_rows OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION claimius.calc_hierarchical_access()', v_schema, v_name);
        EXECUTE format('CREATE TRIGGER tg_calc_access_delete AFTER DELETE ON %I.%I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION claimius.calc_hierarchical_access()', v_schema, v_name);
    END LOOP;
END $$;


DO $$
DECLARE
    v_root UUID;
BEGIN
    DELETE FROM claimius.inheritance_info;

    FOR v_root IN
        SELECT DISTINCT sa_root_id
        FROM claimius.organization
        WHERE sa_root_id IS NOT NULL
    LOOP
        PERFORM claimius.rebuild_tree(v_root);
    END LOOP;

    FOR v_root IN
        SELECT DISTINCT sa_root_id
        FROM claimius.location
        WHERE sa_root_id IS NOT NULL
    LOOP
        PERFORM claimius.rebuild_tree(v_root);
    END LOOP;

    PERFORM claimius.rebuild_user_object();
END $$;
