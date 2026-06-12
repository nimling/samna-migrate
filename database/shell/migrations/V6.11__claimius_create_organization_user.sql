-- ============================================================================
-- V6.11 create_organization_user and user_token.type
-- ----------------------------------------------------------------------------
-- Disciple side helper for minting users under an organization the caller
-- owns. Inserts the samna_user row directly, grants the supplied claim to
-- the user, and binds the caller's claim to the new user as object so the
-- caller's claim universe sees the synthesised user.
--
-- Also adds a type discriminator on claimius.user_token. Rows from the
-- JWT path carry type='token'; rows from the external path carry
-- type='external'.
-- ============================================================================

ALTER TABLE claimius.user_token
    ADD COLUMN IF NOT EXISTS type TEXT NOT NULL DEFAULT 'token';

ALTER TABLE claimius.user_token
    ALTER COLUMN app_id SET DEFAULT claimius.get_disciple_app_id();

CREATE INDEX IF NOT EXISTS idx_user_token_type
    ON claimius.user_token (type) WHERE sa_deleted_at IS NULL;

COMMENT ON COLUMN claimius.user_token.type
    IS 'Binding kind: token for JWT derived, external for direct external_id.';

CREATE OR REPLACE FUNCTION claimius.create_organization_user(
    p_caller_uc  UUID,
    p_caller_cid UUID,
    p_owner_id   UUID,
    p_user       JSONB
) RETURNS JSONB AS $$
DECLARE
    v_app_id     UUID := claimius.get_disciple_app_id();
    v_user_id    UUID;
    v_claim_id   UUID;
    v_root_id    UUID;
    v_user_row   claimius.samna_user;
    v_claim_user JSONB;
    v_claim_obj  JSONB;
BEGIN
    v_user_id  := NULLIF(NULLIF(p_user ->> 'user_id', ''), '00000000-0000-0000-0000-000000000000')::UUID;
    v_claim_id := NULLIF(p_user ->> 'claim_id', '')::UUID;

    IF v_claim_id IS NULL THEN
        RAISE EXCEPTION 'claim_id required';
    END IF;
    IF p_owner_id IS NULL THEN
        RAISE EXCEPTION 'owner_id required';
    END IF;
    IF p_caller_uc IS NULL OR p_caller_cid IS NULL THEN
        RAISE EXCEPTION 'caller context required';
    END IF;

    SELECT sa_root_id INTO v_root_id
      FROM claimius.organization
     WHERE id = p_owner_id
       AND sa_deleted_at IS NULL;

    IF v_root_id IS NULL THEN
        RAISE EXCEPTION 'owner_id invalid';
    END IF;

    INSERT INTO claimius.samna_user (
        user_id, app_id, first_name, last_name, user_name, user_image,
        email, phone, external_id, status, type
    ) VALUES (
        COALESCE(v_user_id, gen_random_uuid()),
        v_app_id,
        NULLIF(p_user ->> 'first_name', ''),
        NULLIF(p_user ->> 'last_name', ''),
        NULLIF(p_user ->> 'user_name', ''),
        NULLIF(p_user ->> 'user_image', ''),
        NULLIF(p_user ->> 'email', ''),
        NULLIF(p_user ->> 'phone', ''),
        NULLIF(p_user ->> 'external_id', ''),
        COALESCE(NULLIF(p_user ->> 'status', ''), 'active')::claimius.user_status,
        'user'
    )
    ON CONFLICT (user_id, app_id) WHERE sa_deleted_at IS NULL DO UPDATE SET
        first_name    = COALESCE(EXCLUDED.first_name, claimius.samna_user.first_name),
        last_name     = COALESCE(EXCLUDED.last_name, claimius.samna_user.last_name),
        user_name     = COALESCE(EXCLUDED.user_name, claimius.samna_user.user_name),
        user_image    = COALESCE(EXCLUDED.user_image, claimius.samna_user.user_image),
        email         = COALESCE(EXCLUDED.email, claimius.samna_user.email),
        phone         = COALESCE(EXCLUDED.phone, claimius.samna_user.phone),
        external_id   = COALESCE(EXCLUDED.external_id, claimius.samna_user.external_id),
        sa_updated_at = now()
    RETURNING * INTO v_user_row;

    v_claim_user := claimius.assign_claim_user(
        p_app_id        => v_app_id,
        p_claim_id      => v_claim_id,
        p_user_id       => v_user_row.user_id,
        p_sa_owner_id   => p_owner_id,
        p_sa_created_by => p_caller_uc
    );

    v_claim_obj := claimius.assign_claim_object(
        p_app_id        => v_app_id,
        p_claim_id      => p_caller_cid,
        p_sa_owner_id   => p_owner_id,
        p_sa_root_id    => v_root_id,
        p_sa_created_by => p_caller_uc,
        p_object_id     => v_user_row.user_id,
        p_object_type   => 'claimius.samna_user'
    );

    RETURN jsonb_build_object(
        'samna_user',   to_jsonb(v_user_row),
        'user_claim',   v_claim_user -> 'user_claim',
        'claim_object', v_claim_obj  -> 'claim_object'
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius.create_organization_user IS
    'Disciple side: upsert samna_user, grant the supplied claim to the user, and bind the caller claim to the new user as object. Returns samna_user, user_claim, claim_object.';

GRANT EXECUTE ON FUNCTION claimius.create_organization_user(UUID, UUID, UUID, JSONB)
    TO claimius_writer, claimius_disciple_client;
