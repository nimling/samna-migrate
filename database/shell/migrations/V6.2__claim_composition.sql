-- ============================================================================
-- V6.2 Claim composition
-- ----------------------------------------------------------------------------
-- A claim_object row whose object_type is 'claimius.claim' is a composition
-- link. Pointing claim A at claim B absorbs B's claim_object bindings into A.
-- Users holding A gain access on every object B is bound to, capped per
-- binding by bitand of A's link mask and B's per binding mask. A does not
-- absorb B's user_claim grants. Single hop. Cycles forbidden at write time.
-- The link stays live: changes to B's mask, B's bindings, or B's soft delete
-- propagate to A's users automatically.
--
-- Surfaces touched:
--   1. claimius._build_grants_for_object  composed_bindings CTE
--   2. claimius.calc_claim_access         fan out branches for composition
--   3. claimius.assign_claim_object       cycle check and access check
--   4. claimius.remove_claim              soft delete inbound links
-- ============================================================================

CREATE OR REPLACE FUNCTION claimius._build_grants_for_object(
    p_user_id     UUID,
    p_app_id      UUID,
    p_object_type TEXT,
    p_object_id   UUID
) RETURNS JSONB AS $$
DECLARE
    v_grants     JSONB := '[]'::JSONB;
    v_denies     JSONB := '[]'::JSONB;
    v_row        RECORD;
    v_grant_bits INTEGER;
    v_deny_bits  INTEGER;
    v_is_deny    BOOLEAN;
BEGIN
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
        ),
        composed_bindings AS (
            SELECT uc.claim_id,
                   'claimius.claim'::TEXT AS cascaded_from_type,
                   link.object_id         AS cascaded_from_id,
                   'composition'::TEXT    AS tree_type,
                   (
                       (
                           COALESCE(link.sa_access, uc.claim_access)
                           & COALESCE(co.sa_access, cb.sa_access)
                       )
                       | (
                           (COALESCE(link.sa_access, uc.claim_access) | COALESCE(co.sa_access, cb.sa_access))
                           & 16
                       )
                   ) AS sa_access,
                   co.scope
            FROM claimius.claim_object link
                JOIN user_claims uc ON uc.claim_id = link.claim_id AND link.inherits = TRUE
                JOIN claimius.claim cb
                    ON cb.id = link.object_id
                   AND cb.sa_deleted_at IS NULL
                   AND cb.inherits = TRUE
                JOIN claimius.claim_object co
                    ON co.claim_id      = link.object_id
                   AND co.object_type   = p_object_type
                   AND co.object_id     = p_object_id
                   AND co.app_id        = p_app_id
                   AND co.sa_deleted_at IS NULL
            WHERE link.object_type = 'claimius.claim'
              AND link.app_id      = p_app_id
              AND link.sa_deleted_at IS NULL
        )
        SELECT * FROM direct_bindings
        UNION ALL
        SELECT * FROM cascaded_bindings
        UNION ALL
        SELECT * FROM composed_bindings
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

    IF jsonb_array_length(v_denies) > 0 THEN
        v_grants := claimius._apply_denies(v_grants, v_denies, p_object_type, p_object_id);
    END IF;

    RETURN v_grants;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._build_grants_for_object IS 'Computes grants jsonb for a (user, object) pair. Walks direct, hierarchy cascaded, and claim composition paths. Applies deny subtraction per (tree_type, cascaded_from) path.';

CREATE OR REPLACE FUNCTION claimius.calc_claim_access()
    RETURNS TRIGGER AS $$
DECLARE
    v_table       TEXT;
    v_app_id      UUID;
    v_claim_id    UUID;
    v_user_id     UUID;
    v_object_id   UUID;
    v_object_type TEXT;
    v_pair        RECORD;
    v_link        RECORD;
    v_b_binding   RECORD;
    v_user_of_a   RECORD;
BEGIN
    IF claimius.in_replay_mode() THEN
        RETURN coalesce(NEW, OLD);
    END IF;

    v_table := TG_TABLE_NAME;

    IF v_table = 'claim' THEN
        v_claim_id := coalesce(NEW.id, OLD.id);
        v_app_id   := coalesce(NEW.app_id, OLD.app_id);

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
            IF coalesce((SELECT inherits FROM claimius.claim WHERE id = v_claim_id), FALSE)
                AND v_pair.co_inherits THEN
                PERFORM claimius._cascade_recompute(v_app_id, v_pair.user_id, v_pair.object_type, v_pair.object_id);
            END IF;
        END LOOP;

        FOR v_link IN
            SELECT link.object_id AS b_id
            FROM claimius.claim_object link
            WHERE link.claim_id      = v_claim_id
              AND link.object_type   = 'claimius.claim'
              AND link.app_id        = v_app_id
              AND link.sa_deleted_at IS NULL
        LOOP
            FOR v_b_binding IN
                SELECT object_type, object_id
                FROM claimius.claim_object
                WHERE claim_id      = v_link.b_id
                  AND app_id        = v_app_id
                  AND sa_deleted_at IS NULL
            LOOP
                FOR v_user_of_a IN
                    SELECT user_id FROM claimius.user_claim
                    WHERE claim_id      = v_claim_id
                      AND app_id        = v_app_id
                      AND sa_deleted_at IS NULL
                LOOP
                    PERFORM claimius.recompute_user_object(
                        v_app_id, v_user_of_a.user_id, v_b_binding.object_type, v_b_binding.object_id);
                END LOOP;
            END LOOP;
        END LOOP;

        FOR v_link IN
            SELECT link.claim_id AS a_id
            FROM claimius.claim_object link
            WHERE link.object_type   = 'claimius.claim'
              AND link.object_id     = v_claim_id
              AND link.app_id        = v_app_id
              AND link.sa_deleted_at IS NULL
        LOOP
            FOR v_b_binding IN
                SELECT object_type, object_id
                FROM claimius.claim_object
                WHERE claim_id      = v_claim_id
                  AND app_id        = v_app_id
                  AND sa_deleted_at IS NULL
            LOOP
                FOR v_user_of_a IN
                    SELECT user_id FROM claimius.user_claim
                    WHERE claim_id      = v_link.a_id
                      AND app_id        = v_app_id
                      AND sa_deleted_at IS NULL
                LOOP
                    PERFORM claimius.recompute_user_object(
                        v_app_id, v_user_of_a.user_id, v_b_binding.object_type, v_b_binding.object_id);
                END LOOP;
            END LOOP;
        END LOOP;

    ELSIF v_table = 'claim_object' THEN
        v_claim_id    := coalesce(NEW.claim_id, OLD.claim_id);
        v_app_id      := coalesce(NEW.app_id, OLD.app_id);
        v_object_id   := coalesce(NEW.object_id, OLD.object_id);
        v_object_type := coalesce(NEW.object_type, OLD.object_type);

        FOR v_pair IN
            SELECT uc.user_id
            FROM claimius.user_claim uc
            WHERE uc.claim_id = v_claim_id
              AND uc.app_id = v_app_id
              AND uc.sa_deleted_at IS NULL
        LOOP
            PERFORM claimius.recompute_user_object(v_app_id, v_pair.user_id, v_object_type, v_object_id);
            IF coalesce(NEW.inherits, OLD.inherits, FALSE)
                AND coalesce((SELECT inherits FROM claimius.claim WHERE id = v_claim_id), FALSE) THEN
                PERFORM claimius._cascade_recompute(v_app_id, v_pair.user_id, v_object_type, v_object_id);
            END IF;
        END LOOP;

        IF v_object_type = 'claimius.claim' THEN
            FOR v_b_binding IN
                SELECT object_type, object_id
                FROM claimius.claim_object
                WHERE claim_id      = v_object_id
                  AND app_id        = v_app_id
                  AND sa_deleted_at IS NULL
            LOOP
                FOR v_user_of_a IN
                    SELECT user_id FROM claimius.user_claim
                    WHERE claim_id      = v_claim_id
                      AND app_id        = v_app_id
                      AND sa_deleted_at IS NULL
                LOOP
                    PERFORM claimius.recompute_user_object(
                        v_app_id, v_user_of_a.user_id, v_b_binding.object_type, v_b_binding.object_id);
                END LOOP;
            END LOOP;
        END IF;

        FOR v_link IN
            SELECT link.claim_id AS a_id
            FROM claimius.claim_object link
            WHERE link.object_type   = 'claimius.claim'
              AND link.object_id     = v_claim_id
              AND link.app_id        = v_app_id
              AND link.sa_deleted_at IS NULL
        LOOP
            FOR v_user_of_a IN
                SELECT user_id FROM claimius.user_claim
                WHERE claim_id      = v_link.a_id
                  AND app_id        = v_app_id
                  AND sa_deleted_at IS NULL
            LOOP
                PERFORM claimius.recompute_user_object(
                    v_app_id, v_user_of_a.user_id, v_object_type, v_object_id);
            END LOOP;
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
            IF v_pair.inherits
                AND coalesce((SELECT inherits FROM claimius.claim WHERE id = v_claim_id), FALSE) THEN
                PERFORM claimius._cascade_recompute(v_app_id, v_user_id, v_pair.object_type, v_pair.object_id);
            END IF;
        END LOOP;

        FOR v_link IN
            SELECT link.object_id AS b_id
            FROM claimius.claim_object link
            WHERE link.claim_id      = v_claim_id
              AND link.object_type   = 'claimius.claim'
              AND link.app_id        = v_app_id
              AND link.sa_deleted_at IS NULL
        LOOP
            FOR v_b_binding IN
                SELECT object_type, object_id
                FROM claimius.claim_object
                WHERE claim_id      = v_link.b_id
                  AND app_id        = v_app_id
                  AND sa_deleted_at IS NULL
            LOOP
                PERFORM claimius.recompute_user_object(
                    v_app_id, v_user_id, v_b_binding.object_type, v_b_binding.object_id);
            END LOOP;
        END LOOP;
    END IF;

    RETURN coalesce(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.calc_claim_access() IS 'Trigger on claim, claim_object, user_claim. Reconciles affected users including composition link fan out.';

CREATE OR REPLACE FUNCTION claimius._check_claim_composition()
    RETURNS TRIGGER AS $$
DECLARE
    v_user_id    UUID;
    v_has_access BOOLEAN;
BEGIN
    IF claimius.in_replay_mode() THEN
        RETURN NEW;
    END IF;

    IF NEW.object_type IS DISTINCT FROM 'claimius.claim' OR NEW.object_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.object_id = NEW.claim_id THEN
        RAISE EXCEPTION 'claim composition cycle: claim % cannot point at itself', NEW.claim_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM claimius.claim_object
        WHERE claim_id      = NEW.object_id
          AND object_type   = 'claimius.claim'
          AND object_id     = NEW.claim_id
          AND app_id        = NEW.app_id
          AND sa_deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'claim composition cycle: % already points at %', NEW.object_id, NEW.claim_id;
    END IF;

    SELECT uc.user_id INTO v_user_id
    FROM claimius.user_claim uc
    WHERE uc.id = NEW.sa_created_by
      AND uc.sa_deleted_at IS NULL;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'sa_created_by % is not a valid user_claim', NEW.sa_created_by;
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM claimius.user_object
        WHERE user_id     = v_user_id
          AND app_id      = NEW.app_id
          AND object_type = 'claimius.claim'
          AND object_id   = NEW.object_id
          AND (sa_access & 4) <> 0
    ) INTO v_has_access;

    IF NOT v_has_access THEN
        RAISE EXCEPTION 'cannot compose: user % has no read access to claim %', v_user_id, NEW.object_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._check_claim_composition() IS 'BEFORE INSERT/UPDATE trigger on claim_object. Enforces composition link invariants: no self loop, no reverse link cycle, caller has read on target claim. Bypassed during disciple replay.';

DROP TRIGGER IF EXISTS tg_check_claim_composition ON claimius.claim_object;
CREATE TRIGGER tg_check_claim_composition
    BEFORE INSERT OR UPDATE ON claimius.claim_object
    FOR EACH ROW EXECUTE FUNCTION claimius._check_claim_composition();

DROP FUNCTION IF EXISTS claimius.remove_claim(UUID, UUID);

CREATE OR REPLACE FUNCTION claimius.remove_claim(
    p_claim_id   UUID,
    p_deleted_by UUID
) RETURNS BOOLEAN AS $$
BEGIN
    UPDATE claimius.claim_object
       SET sa_deleted_at = now()
     WHERE object_type   = 'claimius.claim'
       AND object_id     = p_claim_id
       AND sa_deleted_at IS NULL;

    UPDATE claimius.claim SET sa_deleted_at = now() WHERE id = p_claim_id AND sa_deleted_at IS NULL;
    UPDATE claimius.user_claim SET sa_deleted_at = now() WHERE claim_id = p_claim_id AND sa_deleted_at IS NULL;
    UPDATE claimius.claim_object SET sa_deleted_at = now() WHERE claim_id = p_claim_id AND sa_deleted_at IS NULL;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.remove_claim IS 'Soft deletes a claim, its user_claim, its claim_object, and any inbound composition links pointing at it.';
