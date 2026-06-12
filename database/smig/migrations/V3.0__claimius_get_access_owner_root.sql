CREATE OR REPLACE FUNCTION claimius.get_access(
    p_user_id          UUID,
    p_app_id           UUID,
    p_object_id        UUID,
    p_object_type      TEXT,
    p_required_access  INTEGER DEFAULT 0
) RETURNS TABLE (
                    user_object_id      UUID,
                    user_claim_id       UUID,
                    claim_id            UUID,
                    sa_access           INTEGER,
                    scope               JSONB,
                    sa_owner_id         UUID,
                    sa_root_id          UUID,
                    sa_location_id      UUID,
                    direct_grant        BOOLEAN
                ) AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
        WITH uo AS (
            SELECT u.*
            FROM claimius.user_object u
            WHERE u.user_id = p_user_id
              AND u.app_id = p_app_id
              AND u.object_id = p_object_id
              AND u.object_type = p_object_type
              AND (u.sa_access & p_required_access) = p_required_access
        ),
             surviving AS (
                 SELECT
                     uo.id AS user_object_id,
                     uc.id AS user_claim_id,
                     (g ->> 'claim_id')::UUID AS claim_id,
                     (g ->> 'access')::INTEGER AS access_bits,
                     g -> 'scope' AS grant_scope,
                     uo.sa_owner_id,
                     o.sa_root_id AS sa_root_id,
                     uo.sa_location_id,
                     FALSE AS direct_grant
                 FROM uo
                          LEFT JOIN claimius.organization o
                            ON o.id = uo.sa_owner_id
                           AND o.sa_deleted_at IS NULL
                          CROSS JOIN LATERAL jsonb_array_elements(uo.grants) g
                          JOIN claimius.user_claim uc ON uc.claim_id = (g ->> 'claim_id')::UUID
                     AND uc.user_id = p_user_id
                     AND uc.app_id = p_app_id
                     AND uc.sa_deleted_at IS NULL
                     AND (uc.starts_at IS NULL OR uc.starts_at <= now())
                     AND (uc.ends_at IS NULL OR uc.ends_at > now())
                          JOIN claimius.claim c ON c.id = uc.claim_id
                     AND c.sa_deleted_at IS NULL
                 WHERE ((g ->> 'access')::INTEGER & p_required_access) = p_required_access
             )
        SELECT s.user_object_id, s.user_claim_id, s.claim_id, s.access_bits,
               s.grant_scope, s.sa_owner_id, s.sa_root_id, s.sa_location_id, s.direct_grant
        FROM surviving s
        ORDER BY claimius._popcount(s.access_bits) DESC, s.access_bits DESC
        LIMIT 1;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.get_access(UUID, UUID, UUID, TEXT, INTEGER) IS 'Strongest active claim based grant for one (user, app, object) whose mask covers p_required_access. user_claim_id is the actor token for follow-on writes. sa_root_id is the owning organization root id, suitable for FK to claimius.organization on follow-on claim and claim_object writes.';
