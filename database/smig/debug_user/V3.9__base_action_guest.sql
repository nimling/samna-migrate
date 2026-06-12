SELECT set_config('sauth.debug_user_id', :'sauth_debug_user_id', true);
SELECT set_config('sauth.app_slug', :'sauth_app_slug', true);
SELECT set_config('sauth.debug_private_key', :'sauth_debug_private_key', true);
SELECT set_config('sauth.debug_private_seed', :'sauth_debug_private_seed', true);
SELECT set_config('sauth.debug_client_secret', :'sauth_debug_client_secret', true);
SELECT set_config('claimius.replay_mode', 'true', true);

DO $$
DECLARE
    v_ctx              RECORD;
    v_user_claim_id    UUID;
    v_app_id           UUID;
    v_org_id           UUID;
    v_debug_claim_id   UUID;
    v_guest_claim_id   UUID;
    v_action_id        UUID;
    v_code_id          UUID;
    v_code_owner_id    UUID;
    v_action_object_id UUID;
    v_script           TEXT;
    v_input            JSONB;
    v_description      TEXT := 'Issues a guest user with a token bound to the Debug Guest claim, then redirects to the bookable portal dev server.';
BEGIN
    SELECT * INTO v_ctx FROM public.get_debug_context(current_setting('sauth.debug_user_id')::uuid);
    v_user_claim_id := v_ctx.user_claim_id;
    v_app_id        := v_ctx.app_id;
    v_org_id        := v_ctx.org_id;

    SELECT id INTO v_debug_claim_id
      FROM claimius.claim
     WHERE app_id = v_app_id
       AND name = 'Debug Claim'
       AND sa_deleted_at IS NULL;

    IF v_debug_claim_id IS NULL THEN
        RAISE EXCEPTION 'guest action seed: Debug Claim not found.';
    END IF;

    SELECT id INTO v_guest_claim_id
      FROM claimius.claim
     WHERE app_id = v_app_id
       AND name = 'Debug Guest'
       AND sa_deleted_at IS NULL;

    IF v_guest_claim_id IS NULL THEN
        RAISE EXCEPTION 'guest action seed: Debug Guest claim not found.';
    END IF;

    v_script := E'create_guest_user(input.claim_id)\nreturn redirect_to("https://bookable.dev.dugr.no/")';

    v_input := jsonb_build_object(
        'claim_id', jsonb_build_object(
            'type', 'string',
            'description', 'UUID of the claim to grant the guest user',
            'value', v_guest_claim_id::text,
            'required', true
        )
    );

    SELECT id INTO v_action_id
      FROM action
     WHERE name = 'Guest Access'
       AND sa_deleted_at IS NULL;

    IF v_action_id IS NULL THEN
        v_action_id := gen_random_uuid();
        INSERT INTO action (
            id, name, description, trigger, code, public, continue_on_fail,
            sa_created_by, sa_owner_id, input
        ) VALUES (
            v_action_id,
            'Guest Access',
            v_description,
            'code_scanned',
            v_script,
            true,
            false,
            v_user_claim_id,
            v_org_id,
            v_input
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_debug_claim_id,
            p_object_id     => v_action_id,
            p_object_type   => 'public.action',
            p_sa_owner_id   => v_org_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding action Guest Access'
        );

        RAISE NOTICE 'Inserted Guest Access action for debug user.';
    ELSE
        UPDATE action
           SET code        = v_script,
               input       = v_input,
               description = v_description,
               trigger     = 'code_scanned',
               public      = true,
               continue_on_fail = false
         WHERE id = v_action_id;

        RAISE NOTICE 'Updated Guest Access action body and input.';
    END IF;

    SELECT id, sa_owner_id INTO v_code_id, v_code_owner_id
      FROM code
     WHERE name = 'Debug Code 1'
       AND sa_deleted_at IS NULL
     LIMIT 1;

    IF v_code_id IS NULL THEN
        RAISE NOTICE 'guest action seed: Debug Code 1 not found, skipping action_object binding.';
        RETURN;
    END IF;

    SELECT id INTO v_action_object_id
      FROM action_object
     WHERE action_id   = v_action_id
       AND object_id   = v_code_id
       AND object_type = 'public.code'
       AND sa_deleted_at IS NULL
     LIMIT 1;

    IF v_action_object_id IS NULL THEN
        v_action_object_id := gen_random_uuid();
        INSERT INTO action_object (
            id, action_id, object_id, object_type, priority,
            input, sa_created_by, sa_owner_id, reason
        ) VALUES (
            v_action_object_id,
            v_action_id,
            v_code_id,
            'public.code',
            0,
            '{}'::jsonb,
            v_user_claim_id,
            v_code_owner_id,
            'Seeded Guest Access binding for Debug Code 1'
        );

        PERFORM claimius.assign_claim_object(
            p_app_id        => v_app_id,
            p_claim_id      => v_debug_claim_id,
            p_object_id     => v_action_object_id,
            p_object_type   => 'public.action_object',
            p_sa_owner_id   => v_code_owner_id,
            p_sa_root_id    => v_org_id,
            p_sa_created_by => v_user_claim_id,
            p_sa_access     => 15,
            p_inherits      => TRUE,
            p_reason        => 'Debug claim binding action_object for Debug Code 1'
        );

        RAISE NOTICE 'Bound Guest Access action to Debug Code 1.';
    ELSE
        RAISE NOTICE 'guest action seed: action_object binding for Debug Code 1 already present.';
    END IF;
END $$;
