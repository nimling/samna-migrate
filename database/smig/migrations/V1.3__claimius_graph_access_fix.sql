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
          AND (p_required_access = 0 OR c.sa_access <= p_required_access);
    ELSE
        SELECT array_agg(uc.claim_id) INTO v_claim_ids
        FROM claimius.user_claim uc
                 JOIN claimius.claim c ON c.id = uc.claim_id
        WHERE uc.user_id = p_user_id
          AND uc.app_id = p_app_id
          AND uc.claim_id = p_start_id
          AND uc.sa_deleted_at IS NULL
          AND c.sa_deleted_at IS NULL
          AND (p_required_access = 0 OR c.sa_access <= p_required_access);
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
          AND (p_required_access = 0 OR uo.sa_access <= p_required_access)
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

DO $$ BEGIN DELETE FROM claimius.claim_graph_cache; END $$;
