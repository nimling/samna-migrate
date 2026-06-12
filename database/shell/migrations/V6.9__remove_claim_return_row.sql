DROP FUNCTION IF EXISTS claimius.remove_claim(UUID, UUID);

CREATE OR REPLACE FUNCTION claimius.remove_claim(
    p_claim_id   UUID,
    p_deleted_by UUID
) RETURNS SETOF claimius.claim AS $$
BEGIN
    UPDATE claimius.claim_object
       SET sa_deleted_at = now()
     WHERE object_type   = 'claimius.claim'
       AND object_id     = p_claim_id
       AND sa_deleted_at IS NULL;

    UPDATE claimius.user_claim SET sa_deleted_at = now() WHERE claim_id = p_claim_id AND sa_deleted_at IS NULL;
    UPDATE claimius.claim_object SET sa_deleted_at = now() WHERE claim_id = p_claim_id AND sa_deleted_at IS NULL;
    RETURN QUERY
    UPDATE claimius.claim SET sa_deleted_at = now()
    WHERE id = p_claim_id AND sa_deleted_at IS NULL
    RETURNING *;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.remove_claim IS 'Soft deletes a claim, its user_claim, its claim_object, and any inbound composition links pointing at it. Returns the deleted claim row.';
