CREATE OR REPLACE FUNCTION claimius._refresh_user_users(p_app_id UUID, p_viewer_id UUID)
    RETURNS VOID AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext(p_app_id::TEXT), hashtext(p_viewer_id::TEXT));

    DELETE FROM claimius.user_users
    WHERE app_id = p_app_id AND viewer_id = p_viewer_id;

    INSERT INTO claimius.user_users (id, app_id, viewer_id, target_user_id, sharing_object_count, first_shared_at, last_shared_at)
    SELECT
        claimius.composite_id(p_app_id::TEXT, p_viewer_id::TEXT, target.user_id::TEXT),
        p_app_id,
        p_viewer_id,
        target.user_id,
        count(*),
        min(target.sa_created_at),
        max(target.sa_updated_at)
    FROM claimius.object_users viewer
             JOIN claimius.object_users target
                  ON target.app_id = viewer.app_id
                      AND target.object_id = viewer.object_id
                      AND target.object_type = viewer.object_type
                      AND target.user_id <> viewer.user_id
    WHERE viewer.app_id = p_app_id AND viewer.user_id = p_viewer_id
    GROUP BY target.user_id;
END;
$$ LANGUAGE plpgsql;
