-- ============================================================================
-- V6.3 Statement level calc trigger registration
-- ----------------------------------------------------------------------------
-- claimius.calc_hierarchical_access reads the NEW TABLE transition relation
-- new_rows and the OLD TABLE relation old_rows. The function body installed
-- by V2.1 assumes the trigger declares those REFERENCING clauses and fires
-- FOR EACH STATEMENT. claimius._attach_calc_trigger, the helper used by
-- init_claimius_tables to wire triggers on every registered table, emits a
-- single FOR EACH ROW trigger with no REFERENCING. Registered parenthood
-- tables (public.bookable and any table with both sa_parent_id and
-- sa_root_id) then fire the statement level body without a transition table
-- and raise: relation "new_rows" does not exist.
--
-- This migration overrides _attach_calc_trigger so the hierarchical branch
-- emits three statement level triggers with the required REFERENCING clauses,
-- matching the shape V2.1 installs on already registered tables. The
-- non-hierarchical branch keeps the FOR EACH ROW trigger that
-- calc_object_access expects.
--
-- After replacing the function, re-attach calc triggers on every currently
-- registered table so any table that received the broken FOR EACH ROW shape
-- gets the correct statement level wiring without touching its data.
-- ============================================================================

CREATE OR REPLACE FUNCTION claimius._attach_calc_trigger(p_object_type TEXT)
    RETURNS VOID AS $$
DECLARE
    v_schema        TEXT;
    v_table         TEXT;
    v_parts         TEXT[];
    v_has_parent    BOOLEAN;
    v_has_root      BOOLEAN;
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    IF v_schema = 'claimius' THEN
        RETURN;
    END IF;

    SELECT t.has_sa_parent_id, t.has_sa_root_id
    INTO v_has_parent, v_has_root
    FROM claimius.table_info t WHERE t.object_type = p_object_type;

    EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access ON %I.%I', v_schema, v_table);
    EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access_insert ON %I.%I', v_schema, v_table);
    EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access_update ON %I.%I', v_schema, v_table);
    EXECUTE format('DROP TRIGGER IF EXISTS tg_calc_access_delete ON %I.%I', v_schema, v_table);

    IF v_has_parent AND v_has_root THEN
        EXECUTE format(
            'CREATE TRIGGER tg_calc_access_insert AFTER INSERT ON %I.%I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION claimius.calc_hierarchical_access()',
            v_schema, v_table
        );
        EXECUTE format(
            'CREATE TRIGGER tg_calc_access_update AFTER UPDATE ON %I.%I REFERENCING NEW TABLE AS new_rows OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION claimius.calc_hierarchical_access()',
            v_schema, v_table
        );
        EXECUTE format(
            'CREATE TRIGGER tg_calc_access_delete AFTER DELETE ON %I.%I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION claimius.calc_hierarchical_access()',
            v_schema, v_table
        );
    ELSE
        EXECUTE format(
            'CREATE TRIGGER tg_calc_access AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION claimius.calc_object_access()',
            v_schema, v_table
        );
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._attach_calc_trigger(TEXT) IS 'Attaches the calc trigger to a registered table. Hierarchical tables (sa_parent_id + sa_root_id) get three statement level triggers with REFERENCING transition tables. Object tables get a single FOR EACH ROW trigger.';


DO $$
DECLARE
    v_table claimius.table_info%ROWTYPE;
BEGIN
    FOR v_table IN SELECT * FROM claimius.table_info LOOP
        PERFORM claimius._attach_calc_trigger(v_table.object_type);
    END LOOP;
END $$;

DROP TRIGGER IF EXISTS tg_calc_access ON claimius.audit;
DROP TRIGGER IF EXISTS tg_calc_access ON claimius.samna_app;
DROP TRIGGER IF EXISTS tg_calc_access_insert ON claimius.audit;
DROP TRIGGER IF EXISTS tg_calc_access_update ON claimius.audit;
DROP TRIGGER IF EXISTS tg_calc_access_delete ON claimius.audit;
DROP TRIGGER IF EXISTS tg_calc_access_insert ON claimius.samna_app;
DROP TRIGGER IF EXISTS tg_calc_access_update ON claimius.samna_app;
DROP TRIGGER IF EXISTS tg_calc_access_delete ON claimius.samna_app;
