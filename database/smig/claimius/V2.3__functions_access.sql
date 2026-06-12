-- ============================================================================
-- Claimius V2.3 Access Functions
-- ----------------------------------------------------------------------------
-- The trigger functions that maintain the materialized access state. Three
-- families:
--   calc_object_access        Fires on regular registered tables
--   calc_hierarchical_access  Fires on hierarchical tables (org, location,
--                             parenthood enabled tables)
--   calc_claim_access         Fires on claim, claim_object, user_claim
--   emit_sync_event           Fires on user_object, object_users, user_users
--                             to publish into sync_event
--   audit_trigger             Fires on core auditable tables to write audit
--   tg_update_timestamp       Generic sa_updated_at maintenance
-- ============================================================================

-- ----------------------------------------------------------------------------
-- calc_object_access
-- Trigger function for regular registered tables (no self referencing
-- hierarchy). On any change, recomputes user_object for affected users and
-- splices the row into ownership and (optionally) location trees.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.calc_object_access()
    RETURNS TRIGGER AS $$
DECLARE
    v_object_type   TEXT;
    v_obj_id        UUID;
    v_app_id        UUID;
    v_owner_id      UUID;
    v_location_id   UUID;
    v_user          RECORD;
    v_org_root      UUID;
    v_loc_root      UUID;
    v_owner_level   INTEGER;
    v_loc_level     INTEGER;
    v_op            TEXT;
    v_was_active    BOOLEAN;
    v_is_active     BOOLEAN;
BEGIN
    IF claimius.in_replay_mode() THEN
        RETURN coalesce(NEW, OLD);
    END IF;

    v_object_type := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
    v_op := TG_OP;

    IF v_op = 'DELETE' THEN
        v_obj_id := OLD.id;
    ELSE
        v_obj_id := NEW.id;
    END IF;

    -- Pull useful fields from the row using JSON conversion (works for any
    -- registered shape). app_id comes from the row when the table has it,
    -- otherwise from claimius.get_app_id().
    IF v_op <> 'DELETE' THEN
        v_app_id    := claimius._app_id_for_row(v_object_type, to_jsonb(NEW));
        v_owner_id  := (to_jsonb(NEW) ->> 'sa_owner_id')::UUID;
        v_location_id := (to_jsonb(NEW) ->> 'sa_location_id')::UUID;
        v_is_active := (to_jsonb(NEW) ->> 'sa_deleted_at') IS NULL;
    END IF;
    IF v_op <> 'INSERT' THEN
        v_was_active := (to_jsonb(OLD) ->> 'sa_deleted_at') IS NULL;
        IF v_op = 'DELETE' THEN
            v_app_id := claimius._app_id_for_row(v_object_type, to_jsonb(OLD));
        END IF;
    END IF;

    -- Tree maintenance: detach on delete or hard delete; attach on insert
    -- or undelete; reattach on owner/location change.
    IF v_op = 'DELETE' OR (v_op = 'UPDATE' AND v_was_active AND NOT v_is_active) THEN
        -- detach from any trees this row appeared in
        PERFORM claimius._detach_object_from_trees(v_object_type, v_obj_id, OLD);
    ELSIF v_op = 'INSERT' OR (v_op = 'UPDATE' AND NOT v_was_active AND v_is_active) THEN
        PERFORM claimius._attach_object_to_trees(v_object_type, v_obj_id, NEW);
    ELSIF v_op = 'UPDATE' AND v_is_active THEN
        -- check whether owner or location changed
        IF (to_jsonb(OLD) ->> 'sa_owner_id') IS DISTINCT FROM (to_jsonb(NEW) ->> 'sa_owner_id')
            OR (to_jsonb(OLD) ->> 'sa_location_id') IS DISTINCT FROM (to_jsonb(NEW) ->> 'sa_location_id') THEN
            PERFORM claimius._detach_object_from_trees(v_object_type, v_obj_id, OLD);
            PERFORM claimius._attach_object_to_trees(v_object_type, v_obj_id, NEW);
        END IF;
    END IF;

    -- Recompute user_object for every affected user
    FOR v_user IN
        SELECT user_id FROM claimius._affected_users_for_object(v_app_id, v_object_type, v_obj_id)
        LOOP
            PERFORM claimius.recompute_user_object(v_app_id, v_user.user_id, v_object_type, v_obj_id);
        END LOOP;

    RETURN coalesce(NEW, OLD);
EXCEPTION WHEN OTHERS THEN
    PERFORM claimius.write_audit(
            v_app_id, v_op, 'error', v_object_type, v_obj_id,
            coalesce(v_owner_id, '00000000-0000-0000-0000-000000000000'::UUID),
            coalesce((to_jsonb(coalesce(NEW, OLD)) ->> 'sa_created_by')::UUID, '00000000-0000-0000-0000-000000000000'::UUID),
            SQLERRM
            );
    RAISE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.calc_object_access() IS 'Trigger on regular registered tables. Maintains tree memberships and user_object.';

-- _attach_object_to_trees
-- Splices a non hierarchical row into its ownership and (optionally)
-- location trees by inserting closure edges: a self-edge for the row plus
-- one edge per ancestor of the parent at depth + 1.
CREATE OR REPLACE FUNCTION claimius._attach_object_to_trees(
    p_object_type TEXT,
    p_object_id   UUID,
    p_row         RECORD
) RETURNS VOID AS $$
DECLARE
    v_owner_id  UUID;
    v_loc_id    UUID;
    v_owner_root UUID;
    v_loc_root  UUID;
    v_inserted  INTEGER;
BEGIN
    v_owner_id := (to_jsonb(p_row) ->> 'sa_owner_id')::UUID;
    v_loc_id   := (to_jsonb(p_row) ->> 'sa_location_id')::UUID;

    IF v_owner_id IS NOT NULL THEN
        SELECT sa_root_id INTO v_owner_root
        FROM claimius.organization WHERE id = v_owner_id;
        IF v_owner_root IS NOT NULL THEN
            -- self-edge
            INSERT INTO claimius.inheritance_info (
                tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
            ) VALUES (
                'ownership', v_owner_root, p_object_type, p_object_id, p_object_type, p_object_id, 0
            ) ON CONFLICT DO NOTHING;
            -- ancestor edges via owner's existing closure
            INSERT INTO claimius.inheritance_info (
                tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
            )
            SELECT 'ownership', v_owner_root, e.ancestor_type, e.ancestor_id, p_object_type, p_object_id, e.depth + 1
            FROM claimius.inheritance_info e
            WHERE e.tree_type = 'ownership'
              AND e.root_id = v_owner_root
              AND e.descendant_type = 'claimius.organization'
              AND e.descendant_id   = v_owner_id
            ON CONFLICT DO NOTHING;
            GET DIAGNOSTICS v_inserted = ROW_COUNT;
            -- owner not in tree yet: rebuild from scratch
            IF v_inserted = 0 THEN
                PERFORM claimius.build_ownership_tree(v_owner_root);
            END IF;
        END IF;
    END IF;

    IF v_loc_id IS NOT NULL THEN
        SELECT sa_root_id INTO v_loc_root
        FROM claimius.location WHERE id = v_loc_id;
        IF v_loc_root IS NOT NULL THEN
            INSERT INTO claimius.inheritance_info (
                tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
            ) VALUES (
                'location', v_loc_root, p_object_type, p_object_id, p_object_type, p_object_id, 0
            ) ON CONFLICT DO NOTHING;
            INSERT INTO claimius.inheritance_info (
                tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
            )
            SELECT 'location', v_loc_root, e.ancestor_type, e.ancestor_id, p_object_type, p_object_id, e.depth + 1
            FROM claimius.inheritance_info e
            WHERE e.tree_type = 'location'
              AND e.root_id = v_loc_root
              AND e.descendant_type = 'claimius.location'
              AND e.descendant_id   = v_loc_id
            ON CONFLICT DO NOTHING;
            GET DIAGNOSTICS v_inserted = ROW_COUNT;
            IF v_inserted = 0 THEN
                PERFORM claimius.build_location_tree(v_loc_root);
            END IF;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- _detach_object_from_trees
-- Removes a non hierarchical row from its ownership and location trees by
-- deleting every closure edge where this row appears as descendant. Since
-- the row is non hierarchical it has no descendants of its own.
CREATE OR REPLACE FUNCTION claimius._detach_object_from_trees(
    p_object_type TEXT,
    p_object_id   UUID,
    p_row         RECORD
) RETURNS VOID AS $$
BEGIN
    DELETE FROM claimius.inheritance_info
    WHERE tree_type IN ('ownership', 'location')
      AND descendant_type = p_object_type
      AND descendant_id   = p_object_id;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- calc_hierarchical_access
-- Trigger for hierarchical tables (organization, location, parenthood
-- enabled tables). Maintains the table's own tree plus its membership in
-- ownership and location trees. Disallows cross root reparenting.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.calc_hierarchical_access()
    RETURNS TRIGGER AS $$
DECLARE
    v_object_type   TEXT;
    v_obj_id        UUID;
    v_app_id        UUID;
    v_root_id       UUID;
    v_old_root_id   UUID;
    v_user          RECORD;
    v_op            TEXT;
    v_was_active    BOOLEAN;
    v_is_active     BOOLEAN;
    v_old_root      UUID;
    v_new_root      UUID;
BEGIN
    IF claimius.in_replay_mode() THEN
        RETURN coalesce(NEW, OLD);
    END IF;

    v_object_type := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
    v_op := TG_OP;

    IF v_op = 'DELETE' THEN
        v_obj_id := OLD.id;
    ELSE
        v_obj_id := NEW.id;
    END IF;

    IF v_op <> 'DELETE' THEN
        v_app_id    := claimius._app_id_for_row(v_object_type, to_jsonb(NEW));
        v_root_id   := (to_jsonb(NEW) ->> 'sa_root_id')::UUID;
        v_is_active := (to_jsonb(NEW) ->> 'sa_deleted_at') IS NULL;
    END IF;
    IF v_op <> 'INSERT' THEN
        v_old_root_id := (to_jsonb(OLD) ->> 'sa_root_id')::UUID;
        v_was_active := (to_jsonb(OLD) ->> 'sa_deleted_at') IS NULL;
        IF v_op = 'DELETE' THEN
            v_app_id := claimius._app_id_for_row(v_object_type, to_jsonb(OLD));
        END IF;
    END IF;

    -- Cross root reparenting is not allowed
    IF v_op = 'UPDATE' AND v_old_root_id IS DISTINCT FROM v_root_id THEN
        RAISE EXCEPTION 'Cross root reparenting is not allowed. Use migrate_root() if absolutely required.';
    END IF;

    -- Rebuild the tree this row participates in. For organizations this is
    -- the ownership tree rooted at sa_root_id. For locations, the location
    -- tree. For parenthood enabled external tables, the parenthood tree.
    IF v_object_type = 'claimius.organization' THEN
        PERFORM claimius.build_ownership_tree(coalesce(v_root_id, v_old_root_id));
    ELSIF v_object_type = 'claimius.location' THEN
        PERFORM claimius.build_location_tree(coalesce(v_root_id, v_old_root_id));
        -- a location's owner can also place it under an ownership tree
        PERFORM claimius._reattach_location_in_ownership(v_obj_id, NEW, OLD, v_op);
    ELSE
        PERFORM claimius.build_parenthood_tree(v_object_type, coalesce(v_root_id, v_old_root_id));
    END IF;

    -- Recompute affected users for this row
    FOR v_user IN
        SELECT user_id FROM claimius._affected_users_for_object(v_app_id, v_object_type, v_obj_id)
        LOOP
            PERFORM claimius.recompute_user_object(v_app_id, v_user.user_id, v_object_type, v_obj_id);
        END LOOP;

    -- For descendant rows in the same tree, recompute too. Read descendants
    -- directly from the closure index.
    IF v_object_type IN ('claimius.organization', 'claimius.location') OR (
        SELECT t.has_sa_parent_id AND t.has_sa_root_id FROM claimius.table_info t WHERE t.object_type = v_object_type
    ) THEN
        FOR v_user IN
            WITH descendants AS (
                SELECT DISTINCT e.descendant_type AS object_type, e.descendant_id AS object_id
                FROM claimius.inheritance_info e
                WHERE e.ancestor_type = v_object_type
                  AND e.ancestor_id   = v_obj_id
            ),
                 affected AS (
                     SELECT DISTINCT u.user_id, d.object_type, d.object_id
                     FROM descendants d
                              CROSS JOIN LATERAL claimius._affected_users_for_object(v_app_id, d.object_type, d.object_id) u
                 )
            SELECT * FROM affected
            LOOP
                PERFORM claimius.recompute_user_object(v_app_id, v_user.user_id, v_user.object_type, v_user.object_id);
            END LOOP;
    END IF;

    RETURN coalesce(NEW, OLD);
EXCEPTION WHEN OTHERS THEN
    PERFORM claimius.write_audit(
            v_app_id, v_op, 'error', v_object_type, v_obj_id,
            coalesce((to_jsonb(coalesce(NEW, OLD)) ->> 'sa_owner_id')::UUID, '00000000-0000-0000-0000-000000000000'::UUID),
            coalesce((to_jsonb(coalesce(NEW, OLD)) ->> 'sa_created_by')::UUID, '00000000-0000-0000-0000-000000000000'::UUID),
            SQLERRM
            );
    RAISE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.calc_hierarchical_access() IS 'Trigger on hierarchical tables. Rebuilds affected tree and reconciles users.';

-- _reattach_location_in_ownership
-- A location is also a node in the ownership tree of its sa_owner_id
-- organization. When the owner changes, drop the location's edges from the
-- previous owner's ownership tree and insert fresh edges under the new
-- owner. Closure operations only.
CREATE OR REPLACE FUNCTION claimius._reattach_location_in_ownership(
    p_obj_id UUID, p_new RECORD, p_old RECORD, p_op TEXT
) RETURNS VOID AS $$
DECLARE
    v_old_owner UUID;
    v_new_owner UUID;
    v_old_root  UUID;
    v_new_root  UUID;
    v_inserted  INTEGER;
BEGIN
    IF p_op <> 'INSERT' THEN
        v_old_owner := (to_jsonb(p_old) ->> 'sa_owner_id')::UUID;
    END IF;
    IF p_op <> 'DELETE' THEN
        v_new_owner := (to_jsonb(p_new) ->> 'sa_owner_id')::UUID;
    END IF;

    IF v_old_owner IS NOT NULL THEN
        SELECT sa_root_id INTO v_old_root FROM claimius.organization WHERE id = v_old_owner;
        IF v_old_root IS NOT NULL THEN
            DELETE FROM claimius.inheritance_info
            WHERE tree_type = 'ownership'
              AND root_id = v_old_root
              AND descendant_type = 'claimius.location'
              AND descendant_id   = p_obj_id;
        END IF;
    END IF;

    IF v_new_owner IS NOT NULL THEN
        SELECT sa_root_id INTO v_new_root FROM claimius.organization WHERE id = v_new_owner;
        IF v_new_root IS NOT NULL THEN
            INSERT INTO claimius.inheritance_info (
                tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
            ) VALUES (
                'ownership', v_new_root, 'claimius.location', p_obj_id, 'claimius.location', p_obj_id, 0
            ) ON CONFLICT DO NOTHING;
            INSERT INTO claimius.inheritance_info (
                tree_type, root_id, ancestor_type, ancestor_id, descendant_type, descendant_id, depth
            )
            SELECT 'ownership', v_new_root, e.ancestor_type, e.ancestor_id, 'claimius.location', p_obj_id, e.depth + 1
            FROM claimius.inheritance_info e
            WHERE e.tree_type = 'ownership'
              AND e.root_id = v_new_root
              AND e.descendant_type = 'claimius.organization'
              AND e.descendant_id   = v_new_owner
            ON CONFLICT DO NOTHING;
            GET DIAGNOSTICS v_inserted = ROW_COUNT;
            IF v_inserted = 0 THEN
                PERFORM claimius.build_ownership_tree(v_new_root);
            END IF;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- calc_claim_access
-- Trigger for claim, claim_object, user_claim. When any of these change,
-- find the affected (user, object) pairs and recompute user_object for
-- each.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.calc_claim_access()
    RETURNS TRIGGER AS $$
DECLARE
    v_table         TEXT;
    v_app_id        UUID;
    v_claim_id      UUID;
    v_user_id       UUID;
    v_object_id     UUID;
    v_object_type   TEXT;
    v_pair          RECORD;
BEGIN
    IF claimius.in_replay_mode() THEN
        RETURN coalesce(NEW, OLD);
    END IF;

    v_table := TG_TABLE_NAME;

    IF v_table = 'claim' THEN
        v_claim_id := coalesce(NEW.id, OLD.id);
        v_app_id := coalesce(NEW.app_id, OLD.app_id);
        -- Recompute every (user, object) pair this claim could touch
        FOR v_pair IN
            SELECT uc.user_id, co.object_type, co.object_id, co.inherits AS co_inherits
            FROM claimius.user_claim uc
                     JOIN claimius.claim_object co ON co.claim_id = uc.claim_id
            WHERE uc.claim_id = v_claim_id
              AND uc.app_id = v_app_id
              AND uc.sa_deleted_at IS NULL
              AND co.sa_deleted_at IS NULL
            LOOP
                PERFORM claimius.recompute_user_object(v_app_id, v_pair.user_id, v_pair.object_type, v_pair.object_id);
                -- Cascade only when BOTH the claim and this specific claim_object
                -- have inherits = TRUE. claim.inherits is the master switch;
                -- claim_object.inherits is the per binding override.
                IF coalesce((SELECT inherits FROM claimius.claim WHERE id = v_claim_id), FALSE)
                    AND v_pair.co_inherits THEN
                    PERFORM claimius._cascade_recompute(v_app_id, v_pair.user_id, v_pair.object_type, v_pair.object_id);
                END IF;
            END LOOP;

    ELSIF v_table = 'claim_object' THEN
        v_claim_id  := coalesce(NEW.claim_id, OLD.claim_id);
        v_app_id    := coalesce(NEW.app_id, OLD.app_id);
        v_object_id := coalesce(NEW.object_id, OLD.object_id);
        v_object_type := coalesce(NEW.object_type, OLD.object_type);

        FOR v_pair IN
            SELECT uc.user_id
            FROM claimius.user_claim uc
            WHERE uc.claim_id = v_claim_id
              AND uc.app_id = v_app_id
              AND uc.sa_deleted_at IS NULL
            LOOP
                PERFORM claimius.recompute_user_object(v_app_id, v_pair.user_id, v_object_type, v_object_id);
                -- Cascade only when BOTH the claim and this claim_object have
                -- inherits = TRUE.
                IF coalesce(NEW.inherits, OLD.inherits, FALSE)
                    AND coalesce((SELECT inherits FROM claimius.claim WHERE id = v_claim_id), FALSE) THEN
                    PERFORM claimius._cascade_recompute(v_app_id, v_pair.user_id, v_object_type, v_object_id);
                END IF;
            END LOOP;

    ELSIF v_table = 'user_claim' THEN
        v_claim_id := coalesce(NEW.claim_id, OLD.claim_id);
        v_user_id  := coalesce(NEW.user_id, OLD.user_id);
        v_app_id   := coalesce(NEW.app_id, OLD.app_id);

        FOR v_pair IN
            SELECT co.object_type, co.object_id, co.inherits
            FROM claimius.claim_object co
            WHERE co.claim_id = v_claim_id
              AND co.app_id = v_app_id
              AND co.sa_deleted_at IS NULL
            LOOP
                PERFORM claimius.recompute_user_object(v_app_id, v_user_id, v_pair.object_type, v_pair.object_id);
                -- Cascade only when BOTH the claim and the binding inherit.
                IF v_pair.inherits
                    AND coalesce((SELECT inherits FROM claimius.claim WHERE id = v_claim_id), FALSE) THEN
                    PERFORM claimius._cascade_recompute(v_app_id, v_user_id, v_pair.object_type, v_pair.object_id);
                END IF;
            END LOOP;
    END IF;

    RETURN coalesce(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.calc_claim_access() IS 'Trigger on claim, claim_object, user_claim. Reconciles affected users.';

-- _cascade_recompute
-- For an inheritable binding to (object_type, object_id), recomputes
-- user_object for every descendant of that node in every tree it appears
-- in, for the given user.
CREATE OR REPLACE FUNCTION claimius._cascade_recompute(
    p_app_id        UUID,
    p_user_id       UUID,
    p_object_type   TEXT,
    p_object_id     UUID
) RETURNS VOID AS $$
DECLARE
    v_descendant RECORD;
BEGIN
    FOR v_descendant IN
        SELECT DISTINCT e.descendant_type AS object_type, e.descendant_id AS object_id
        FROM claimius.inheritance_info e
        WHERE e.ancestor_type = p_object_type
          AND e.ancestor_id   = p_object_id
        LOOP
            PERFORM claimius.recompute_user_object(p_app_id, p_user_id, v_descendant.object_type, v_descendant.object_id);
        END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- emit_sync_event
-- Trigger function that publishes changes from user_object, object_users,
-- and user_users into sync_event. Disciples consume from sync_event by seq.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claimius.emit_sync_event()
    RETURNS TRIGGER AS $$
DECLARE
    v_op    claimius.sync_operation;
    v_type  TEXT;
    v_payload JSONB;
BEGIN
    IF claimius.in_replay_mode() THEN
        RETURN coalesce(NEW, OLD);
    END IF;

    v_type := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;

    IF TG_OP = 'DELETE' THEN
        v_op := 'delete';
        v_payload := jsonb_build_object('id', (to_jsonb(OLD) ->> 'id'));
    ELSE
        v_op := 'upsert';
        v_payload := to_jsonb(NEW);
    END IF;

    INSERT INTO claimius.sync_event (operation, event_type, payload)
    VALUES (v_op, v_type, v_payload);

    RETURN coalesce(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.emit_sync_event() IS 'Trigger on materialized state tables. Publishes into sync_event.';

-- ----------------------------------------------------------------------------
-- Read time self heal
-- ----------------------------------------------------------------------------

-- reconcile_if_pending
-- Drains reconcile_queue entries for one user inline. Called at the top of
-- every get_* function. Disciple side use only; on the prophet there are
-- normally no entries.
CREATE OR REPLACE FUNCTION claimius.reconcile_if_pending(p_app_id UUID, p_user_id UUID)
    RETURNS VOID AS $$
DECLARE
    v_row RECORD;
BEGIN
    FOR v_row IN
        SELECT id, object_id, object_type FROM claimius.reconcile_queue
        WHERE app_id = p_app_id AND user_id = p_user_id
            FOR UPDATE SKIP LOCKED
        LOOP
            BEGIN
                PERFORM claimius.recompute_user_object(p_app_id, p_user_id, v_row.object_type, v_row.object_id);
                DELETE FROM claimius.reconcile_queue WHERE id = v_row.id;
            EXCEPTION WHEN OTHERS THEN
                -- leave it queued for the next attempt
                NULL;
            END;
        END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.reconcile_if_pending IS 'Drains reconcile_queue for a user inline. Called at read entry points.';

-- cascade_user_soft_delete
-- When read functions detect a soft deleted user, propagate the soft delete
-- to their user_claim, user_relation, and user_field rows.
CREATE OR REPLACE FUNCTION claimius.cascade_user_soft_delete(p_app_id UUID, p_user_id UUID)
    RETURNS VOID AS $$
BEGIN
    UPDATE claimius.user_claim
    SET sa_deleted_at = now()
    WHERE user_id = p_user_id AND app_id = p_app_id AND sa_deleted_at IS NULL;

    UPDATE claimius.user_relation
    SET sa_deleted_at = now()
    WHERE user_id = p_user_id AND app_id = p_app_id AND sa_deleted_at IS NULL;

    UPDATE claimius.user_field
    SET sa_deleted_at = now()
    WHERE user_id = p_user_id AND app_id = p_app_id AND sa_deleted_at IS NULL;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.cascade_user_soft_delete IS 'Propagates soft delete from samna_user to dependent rows.';

-- check_user_active
-- Returns true if the user is active, otherwise cascades and returns false.
-- Used at the top of get_* functions.
CREATE OR REPLACE FUNCTION claimius.check_user_active(p_app_id UUID, p_user_id UUID)
    RETURNS BOOLEAN AS $$
DECLARE
    v_status        claimius.user_status;
    v_deleted       TIMESTAMPTZ;
BEGIN
    SELECT status, sa_deleted_at INTO v_status, v_deleted
    FROM claimius.samna_user
    WHERE user_id = p_user_id AND app_id = p_app_id;

    IF v_status IS NULL THEN
        RETURN FALSE;
    END IF;

    IF v_status <> 'active' OR v_deleted IS NOT NULL THEN
        PERFORM claimius.cascade_user_soft_delete(p_app_id, p_user_id);
        RETURN FALSE;
    END IF;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.check_user_active IS 'Verifies user is active, cascading soft delete otherwise.';

-- ----------------------------------------------------------------------------
-- Self root triggers
-- BEFORE INSERT triggers that fill self referencing parent and root columns.
--   Root row (parent column NULL or = NEW.id): set parent column and
--   sa_root_id to NEW.id.
--   Child row (parent column set, sa_root_id NULL): copy sa_root_id from
--   the parent row.
-- Three variants by hierarchy: organization (sa_owner_id), location
-- (sa_parent_id, lookup in same table), parenthood (sa_parent_id, lookup in
-- the firing table via TG_TABLE_*).
-- ----------------------------------------------------------------------------

-- For organizations. Parent column is sa_owner_id; lookup target is
-- claimius.organization.
CREATE OR REPLACE FUNCTION claimius._set_self_owner_on_insert()
    RETURNS TRIGGER AS $$
DECLARE
    v_root UUID;
    v_zero CONSTANT UUID := '00000000-0000-0000-0000-000000000000'::uuid;
BEGIN
    IF NEW.sa_root_id  = v_zero THEN NEW.sa_root_id  := NULL; END IF;
    IF NEW.sa_owner_id = v_zero THEN NEW.sa_owner_id := NULL; END IF;

    -- Caller already provided sa_root_id: trust it.
    IF NEW.sa_root_id IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- New root: self reference both columns.
    IF NEW.sa_owner_id IS NULL OR NEW.sa_owner_id = NEW.id THEN
        NEW.sa_owner_id := NEW.id;
        NEW.sa_root_id  := NEW.id;
        RETURN NEW;
    END IF;

    -- Child: copy parent org's sa_root_id.
    SELECT sa_root_id INTO v_root
    FROM claimius.organization
    WHERE id = NEW.sa_owner_id;

    NEW.sa_root_id := coalesce(v_root, NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._set_self_owner_on_insert IS 'BEFORE INSERT for organizations. Self references on root creation; copies parent org sa_root_id otherwise.';

-- For locations.
-- Parent column is sa_parent_id (locations belong to a location tree).
-- Lookup target is claimius.location (parent is in the same table).
-- sa_owner_id is required and not auto filled.
CREATE OR REPLACE FUNCTION claimius._set_self_root_on_insert()
    RETURNS TRIGGER AS $$
DECLARE
    v_root UUID;
    v_zero CONSTANT UUID := '00000000-0000-0000-0000-000000000000'::uuid;
BEGIN
    IF NEW.sa_root_id   = v_zero THEN NEW.sa_root_id   := NULL; END IF;
    IF NEW.sa_parent_id = v_zero THEN NEW.sa_parent_id := NULL; END IF;

    IF NEW.sa_root_id IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- New root: parent self references, sa_root_id self references.
    IF NEW.sa_parent_id IS NULL OR NEW.sa_parent_id = NEW.id THEN
        NEW.sa_parent_id := NEW.id;
        NEW.sa_root_id   := NEW.id;
        RETURN NEW;
    END IF;

    -- Child: copy parent location's sa_root_id.
    SELECT sa_root_id INTO v_root
    FROM claimius.location
    WHERE id = NEW.sa_parent_id;

    NEW.sa_root_id := coalesce(v_root, NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._set_self_root_on_insert IS 'BEFORE INSERT for locations. Self references on root creation; copies parent location sa_root_id otherwise.';

-- For parenthood tables. Parent column is sa_parent_id; lookup target is
-- the same table the trigger fires on (TG_TABLE_*).
CREATE OR REPLACE FUNCTION claimius._set_self_parent_on_insert()
    RETURNS TRIGGER AS $$
DECLARE
    v_root  UUID;
    v_sql   TEXT;
    v_zero  CONSTANT UUID := '00000000-0000-0000-0000-000000000000'::uuid;
BEGIN
    IF NEW.sa_root_id   = v_zero THEN NEW.sa_root_id   := NULL; END IF;
    IF NEW.sa_parent_id = v_zero THEN NEW.sa_parent_id := NULL; END IF;

    IF NEW.sa_root_id IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- New root.
    IF NEW.sa_parent_id IS NULL OR NEW.sa_parent_id = NEW.id THEN
        NEW.sa_parent_id := NEW.id;
        NEW.sa_root_id   := NEW.id;
        RETURN NEW;
    END IF;

    -- Child: dynamic lookup against the same table.
    v_sql := format('SELECT sa_root_id FROM %I.%I WHERE id = $1', TG_TABLE_SCHEMA, TG_TABLE_NAME);
    EXECUTE v_sql INTO v_root USING NEW.sa_parent_id;

    NEW.sa_root_id := coalesce(v_root, NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._set_self_parent_on_insert IS 'BEFORE INSERT for parenthood tables. Self references on root creation; copies parent sa_root_id from the same table otherwise.';