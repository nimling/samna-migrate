-- ============================================================================
-- Claimius V0.0 Roles
-- ----------------------------------------------------------------------------
-- Defines the four Postgres roles that gate access to the claimius schema.
-- Roles are the first line of enforcement for the prophet/disciple model.
-- Per-function GRANT EXECUTE statements live in the respective function
-- migration files.
--
-- Roles:
--   claimius_admin            Migration owner. Full access. Used to run
--                             migrations and bootstrap.
--   claimius_writer           Prophet runtime. Can execute write functions.
--                             Used by the prophet's application connection.
--   claimius_reader           Read only. Can execute get_* functions.
--                             Used by app code on prophet and disciple.
--   claimius_disciple_client  Disciple sync layer. Can upsert into specific
--                             tables and update sync state. Cannot execute
--                             write functions. Used by the disciple's sync
--                             middleware.
-- ============================================================================

DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'claimius_admin') THEN
            CREATE ROLE claimius_admin;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'claimius_writer') THEN
            CREATE ROLE claimius_writer;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'claimius_reader') THEN
            CREATE ROLE claimius_reader;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'claimius_disciple_client') THEN
            CREATE ROLE claimius_disciple_client;
        END IF;
    END $$;

CREATE SCHEMA IF NOT EXISTS claimius AUTHORIZATION claimius_admin;

GRANT USAGE ON SCHEMA claimius TO claimius_writer;
GRANT USAGE ON SCHEMA claimius TO claimius_reader;
GRANT USAGE ON SCHEMA claimius TO claimius_disciple_client;