-- ============================================================================
-- Claimius V4.0 Init
-- ----------------------------------------------------------------------------
-- Final step in claimius's own migration set. Registers the internal
-- claimius.* tables in table_info, completing schema setup.
--
-- After this file runs, the schema is "ready" for the implementing app to:
--   1. Run init_prophet, init_disciple, or init_hybrid (as appropriate)
--   2. Run init_claimius_tables(...) with their app's table list
--
-- The implementer's migration tooling is responsible for those calls. They
-- are NOT included in claimius's own migrations.
-- ============================================================================

DO $$
    BEGIN
        PERFORM claimius.init_claimius_internal();
        RAISE NOTICE 'Claimius internal tables registered. Schema ready.';
        RAISE NOTICE 'Implementer must now call: init_prophet | init_disciple | init_hybrid';
        RAISE NOTICE 'Then: init_claimius_tables(VARIADIC <schema.table list>)';
    END $$;