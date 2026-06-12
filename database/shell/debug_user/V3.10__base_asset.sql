SELECT set_config('sauth.debug_user_id', :'sauth_debug_user_id', true);
SELECT set_config('sauth.app_slug', :'sauth_app_slug', true);
SELECT set_config('sauth.debug_private_key', :'sauth_debug_private_key', true);
SELECT set_config('sauth.debug_private_seed', :'sauth_debug_private_seed', true);
SELECT set_config('sauth.debug_client_secret', :'sauth_debug_client_secret', true);
SELECT set_config('claimius.replay_mode', 'true', true);

DO $$
DECLARE
    v_ctx           RECORD;
    v_user_claim_id UUID;
    v_app_id        UUID;
    v_org_id        UUID;
    v_claim_id      UUID;
    v_asset_id      UUID;
BEGIN
    SELECT * INTO v_ctx FROM public.get_debug_context(current_setting('sauth.debug_user_id')::uuid);
    v_user_claim_id := v_ctx.user_claim_id;
    v_app_id        := v_ctx.app_id;
    v_org_id        := v_ctx.org_id;

    SELECT id INTO v_claim_id
      FROM claimius.claim
     WHERE app_id = v_app_id
       AND name = 'Debug Claim'
       AND sa_deleted_at IS NULL;

    IF v_claim_id IS NULL THEN
        RAISE EXCEPTION 'asset seed: Debug Claim not found.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM asset
         WHERE name = 'Debug Asset Pending'
           AND sa_deleted_at IS NULL
    ) THEN
        RAISE NOTICE 'asset debug seed already populated.';
        RETURN;
    END IF;

    v_asset_id := gen_random_uuid();
    INSERT INTO asset (
        id, name, description, mime_type, status, blob_url,
        sa_owner_id, sa_created_by
    ) VALUES (
        v_asset_id,
        'Debug Asset Pending',
        'Debug fixture asset without uploaded data',
        'image/png',
        'pending',
        NULL,
        v_org_id,
        v_user_claim_id
    );

    PERFORM claimius.assign_claim_object(
        p_app_id        => v_app_id,
        p_claim_id      => v_claim_id,
        p_object_id     => v_asset_id,
        p_object_type   => 'public.asset',
        p_sa_owner_id   => v_org_id,
        p_sa_root_id    => v_org_id,
        p_sa_created_by => v_user_claim_id,
        p_sa_access     => 15,
        p_inherits      => TRUE
    );

    RAISE NOTICE 'Inserted 1 asset row (status=pending, no blob) bound to Debug Claim.';
END $$;
