CREATE OR REPLACE FUNCTION claimius._detach_calc_trigger(p_object_type TEXT)
    RETURNS VOID AS $$
DECLARE
    v_parts TEXT[];
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = v_parts[1] AND table_name = v_parts[2]
    ) THEN
        EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access ON %I.%I', v_parts[1], v_parts[2]);
        EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access_insert ON %I.%I', v_parts[1], v_parts[2]);
        EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access_update ON %I.%I', v_parts[1], v_parts[2]);
        EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access_delete ON %I.%I', v_parts[1], v_parts[2]);
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._detach_calc_trigger(TEXT) IS 'Removes all calc triggers from a deregistered table.';

CREATE OR REPLACE FUNCTION claimius._attach_calc_trigger(p_object_type TEXT)
    RETURNS VOID AS $$
DECLARE
    v_schema       TEXT;
    v_table        TEXT;
    v_parts        TEXT[];
    v_has_parent   BOOLEAN;
    v_has_root     BOOLEAN;
    v_hierarchical BOOLEAN;
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    SELECT t.has_sa_parent_id, t.has_sa_root_id
    INTO v_has_parent, v_has_root
    FROM claimius.table_info t
    WHERE t.object_type = p_object_type;

    v_hierarchical := p_object_type IN ('claimius.organization', 'claimius.location')
        OR (COALESCE(v_has_parent, FALSE) AND COALESCE(v_has_root, FALSE));

    PERFORM claimius._detach_calc_trigger(p_object_type);

    IF v_hierarchical THEN
        EXECUTE format(
            'CREATE TRIGGER tg_calc_access_insert AFTER INSERT ON %I.%I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION claimius.calc_hierarchical_access()',
            v_schema, v_table);
        EXECUTE format(
            'CREATE TRIGGER tg_calc_access_update AFTER UPDATE ON %I.%I REFERENCING NEW TABLE AS new_rows OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION claimius.calc_hierarchical_access()',
            v_schema, v_table);
        EXECUTE format(
            'CREATE TRIGGER tg_calc_access_delete AFTER DELETE ON %I.%I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION claimius.calc_hierarchical_access()',
            v_schema, v_table);
    ELSE
        EXECUTE format(
            'CREATE TRIGGER tg_calc_access AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION claimius.calc_object_access()',
            v_schema, v_table);
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._attach_calc_trigger(TEXT) IS 'Attaches calc triggers for a registered table. Hierarchical tables use statement-level transition tables.';

DO $$
DECLARE
    v_object_type TEXT;
BEGIN
    FOR v_object_type IN
        SELECT t.object_type
        FROM claimius.table_info t
        WHERE t.object_type IN ('claimius.organization', 'claimius.location')
           OR (t.has_sa_parent_id AND t.has_sa_root_id)
    LOOP
        PERFORM claimius._attach_calc_trigger(v_object_type);
    END LOOP;
END $$;
