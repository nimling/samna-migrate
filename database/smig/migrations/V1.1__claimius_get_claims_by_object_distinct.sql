CREATE OR REPLACE FUNCTION claimius.get_claims(
    p_user_id       UUID,
    p_app_id        UUID,
    p_object_id     UUID,
    p_object_type   TEXT
) RETURNS SETOF claimius.claim AS $$
BEGIN
    PERFORM claimius.reconcile_if_pending(p_app_id, p_user_id);

    IF NOT claimius.check_user_active(p_app_id, p_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
        SELECT c.*
        FROM claimius.claim c
        WHERE c.sa_deleted_at IS NULL
          AND c.id IN (
              SELECT uc.claim_id
              FROM claimius.user_object uo
                       CROSS JOIN LATERAL jsonb_array_elements(uo.grants) g
                       JOIN claimius.user_claim uc ON uc.claim_id = (g ->> 'claim_id')::UUID
                  AND uc.user_id = p_user_id
                  AND uc.app_id = p_app_id
                  AND uc.sa_deleted_at IS NULL
                  AND (uc.starts_at IS NULL OR uc.starts_at <= now())
                  AND (uc.ends_at IS NULL OR uc.ends_at > now())
              WHERE uo.user_id = p_user_id
                AND uo.app_id = p_app_id
                AND uo.object_id = p_object_id
                AND uo.object_type = p_object_type
          )
        ORDER BY claimius._popcount(c.sa_access) DESC;
END;
$$ LANGUAGE plpgsql;
