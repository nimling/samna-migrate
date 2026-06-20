CREATE EXTENSION IF NOT EXISTS pgcrypto;

SELECT set_config('sauth.debug_user_id', :'sauth_debug_user_id', true);
SELECT set_config('sauth.app_slug', :'sauth_app_slug', true);
SELECT set_config('sauth.debug_private_key', :'sauth_debug_private_key', true);
SELECT set_config('sauth.debug_private_seed', :'sauth_debug_private_seed', true);
SELECT set_config('sauth.debug_client_secret', :'sauth_debug_client_secret', true);

CREATE OR REPLACE FUNCTION public.get_debug_context(p_user_id UUID)
RETURNS TABLE (
    user_claim_id UUID,
    app_id        UUID,
    org_id        UUID
) AS $$
DECLARE
    v_app_slug      TEXT := current_setting('sauth.app_slug');
    v_private_key   TEXT := current_setting('sauth.debug_private_key');
    v_private_seed  TEXT := current_setting('sauth.debug_private_seed');
    v_client_secret TEXT := current_setting('sauth.debug_client_secret');
    v_app_id        UUID;
    v_org_id        UUID := 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
    v_user_claim_id UUID;
    v_claim_id      UUID;
BEGIN
    PERFORM claimius.init_disciple(v_app_slug);

    INSERT INTO claimius.samna_app (
        slug, name, description, private_key, private_seed, sa_owner_id, sa_created_by
    ) VALUES (
        v_app_slug, 'Debug App', 'Debug bootstrap app',
        v_private_key, v_private_seed,
        p_user_id, p_user_id
    )
    ON CONFLICT (slug) DO UPDATE SET
        private_key   = EXCLUDED.private_key,
        private_seed  = EXCLUDED.private_seed,
        sa_updated_at = now();

    v_app_id := claimius.get_disciple_app_id();

    INSERT INTO claimius.organization (
        id, app_id, name, type, sa_owner_id, sa_root_id, sa_level, sa_created_by
    ) VALUES (
        v_org_id, v_app_id, 'Debug Organization', 'company',
        v_org_id, v_org_id, 0, p_user_id
    )
    ON CONFLICT (id) DO NOTHING;

    PERFORM claimius.ensure_app_user(
        p_user_id    => p_user_id,
        p_app_id     => v_app_id,
        p_first_name => 'Debug',
        p_last_name  => 'User',
        p_email      => 'debug@local'
    );

    SELECT claim.id INTO v_claim_id
      FROM claimius.claim
     WHERE claim.app_id        = v_app_id
       AND claim.name          = 'Owner'
       AND claim.sa_owner_id   = v_org_id
       AND claim.sa_deleted_at IS NULL
     LIMIT 1;

    IF v_claim_id IS NULL THEN
        v_claim_id := (claimius.create_claim(
            p_app_id        => v_app_id,
            p_name          => 'Owner',
            p_description   => 'Owner of debug organization',
            p_sa_access     => 1,
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => p_user_id
        ) -> 'claim' ->> 'id')::UUID;

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_object_id     => v_org_id,
            p_object_type   => 'claimius.organization',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => p_user_id,
            p_sa_access     => 15
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM claimius.user_claim
         WHERE user_claim.app_id        = v_app_id
           AND user_claim.claim_id      = v_claim_id
           AND user_claim.user_id       = p_user_id
           AND user_claim.sa_deleted_at IS NULL
    ) THEN
        PERFORM claimius.assign_claim_user(
            p_app_id        => v_app_id,
            p_claim_id      => v_claim_id,
            p_user_id       => p_user_id,
            p_sa_owner_id   => v_org_id,
            p_sa_created_by => p_user_id
        );
    END IF;

    IF v_client_secret <> '' THEN
        INSERT INTO claimius.samna_client (
            id, client_id, name, app_id, secret_hash, sa_owner_id, sa_created_by
        ) VALUES (
            p_user_id, p_user_id, 'Debug Client', v_app_id,
            crypt(v_client_secret, gen_salt('bf')),
            v_org_id, p_user_id
        )
        ON CONFLICT (id) DO UPDATE SET
            secret_hash   = EXCLUDED.secret_hash,
            sa_updated_at = now();
    END IF;

    SELECT uc.id, uc.sa_owner_id
      INTO v_user_claim_id, v_org_id
      FROM claimius.user_claim uc
      JOIN claimius.claim c ON c.id = uc.claim_id
     WHERE uc.user_id = p_user_id
       AND uc.app_id  = v_app_id
       AND uc.sa_deleted_at IS NULL
       AND c.sa_deleted_at IS NULL
     ORDER BY claimius._popcount(c.sa_access) ASC
     LIMIT 1;

    IF v_user_claim_id IS NULL THEN
        RAISE EXCEPTION 'get_debug_context: no user_claim resolved for user % in app %.', p_user_id, v_app_id;
    END IF;

    RETURN QUERY SELECT v_user_claim_id, v_app_id, v_org_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.get_debug_context(p_user_id uuid) IS 'Idempotently bootstraps the debug identity (samna_app, organization, samna_user, samna_client, owner claim, owner user_claim) and returns the bootstrap user_claim id, app id, and org id. Reads the app slug and debug client secret from current_setting. samna_client is provisioned with the same UUID as the debug user so user_claim grants apply to both identities under the shared user_id space. Safe to call repeatedly with different p_user_id values; subsequent users share the same root debug organization and Owner claim.';

DO $$
DECLARE
    v_app_slug      TEXT := current_setting('sauth.app_slug');
    v_debug_user_id UUID := current_setting('sauth.debug_user_id')::uuid;
    v_app_id        UUID;
    v_root_org_id   UUID;
    v_actor_uc_id   UUID;
    r               RECORD;
BEGIN
    SELECT id INTO v_app_id FROM claimius.samna_app WHERE slug = v_app_slug;
    IF v_app_id IS NULL THEN
        RAISE NOTICE 'debug cleanup: app not yet bootstrapped, nothing to remove.';
        RETURN;
    END IF;

    SELECT id INTO v_root_org_id
      FROM claimius.organization
     WHERE app_id = v_app_id
       AND name = 'Debug Organization'
       AND sa_level = 0
       AND sa_deleted_at IS NULL;

    IF v_root_org_id IS NULL THEN
        RAISE NOTICE 'debug cleanup: root debug organization not found, nothing to remove.';
        RETURN;
    END IF;

    SELECT uc.id INTO v_actor_uc_id
      FROM claimius.user_claim uc
      JOIN claimius.claim c ON c.id = uc.claim_id
     WHERE uc.user_id = v_debug_user_id
       AND uc.app_id = v_app_id
       AND uc.sa_deleted_at IS NULL
       AND c.sa_deleted_at IS NULL
     ORDER BY claimius._popcount(c.sa_access) ASC
     LIMIT 1;

    DELETE FROM activity
     WHERE sa_owner_id IN (
         SELECT id FROM claimius.organization
          WHERE app_id = v_app_id
            AND (id = v_root_org_id OR sa_root_id = v_root_org_id)
     );

    DELETE FROM booking
     WHERE name LIKE 'Debug %';

    DELETE FROM object_timeslot
     WHERE reason LIKE 'Bind timeslot %'
        OR reason = 'Debug activity fixture';

    DELETE FROM object_capability
     WHERE reason LIKE 'Capability binding %';

    DELETE FROM checkin
     WHERE object_type = 'public.bookable'
       AND object_id IN (SELECT id FROM bookable WHERE name LIKE 'Debug %');

    DELETE FROM code
     WHERE name LIKE 'Debug %';

    DELETE FROM bookable
     WHERE name LIKE 'Debug %';

    DELETE FROM capability
     WHERE name LIKE 'Debug %';

    DELETE FROM timeslot
     WHERE name LIKE 'Debug %';

    DELETE FROM bookable_type
     WHERE name LIKE 'Debug %';

    FOR r IN SELECT id FROM claimius.claim
              WHERE app_id = v_app_id
                AND name = 'Debug Claim'
                AND sa_deleted_at IS NULL
    LOOP
        PERFORM claimius.remove_claim(r.id, v_actor_uc_id);
    END LOOP;

    UPDATE claimius.samna_client SET sa_deleted_at = now()
     WHERE app_id = v_app_id
       AND name LIKE 'Debug Sub %'
       AND sa_deleted_at IS NULL;

    UPDATE claimius.location SET sa_deleted_at = now()
     WHERE app_id = v_app_id AND name LIKE 'Debug %' AND sa_deleted_at IS NULL;

    UPDATE claimius.organization SET sa_deleted_at = now()
     WHERE app_id = v_app_id
       AND sa_root_id = v_root_org_id
       AND id <> v_root_org_id
       AND name LIKE 'Debug Sub Org %'
       AND sa_deleted_at IS NULL;

    RAISE NOTICE 'debug cleanup: removed prior debug data under root debug organization.';
END $$;
