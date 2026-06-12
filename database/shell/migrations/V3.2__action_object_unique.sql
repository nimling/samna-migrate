UPDATE action_object
SET sa_deleted_at = NOW()
WHERE id IN (
    SELECT id FROM (
        SELECT id,
               ROW_NUMBER() OVER (
                   PARTITION BY action_id, object_type, object_id
                   ORDER BY sa_created_at ASC, id ASC
               ) AS rn
        FROM action_object
        WHERE sa_deleted_at IS NULL
    ) t
    WHERE rn > 1
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_action_object_active
    ON action_object (action_id, object_type, object_id)
    WHERE sa_deleted_at IS NULL;
