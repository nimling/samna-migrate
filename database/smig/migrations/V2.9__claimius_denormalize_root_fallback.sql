CREATE OR REPLACE FUNCTION claimius._denormalize_object(
    p_object_type   TEXT,
    p_object_id     UUID,
    OUT sa_name TEXT,
    OUT sa_description TEXT,
    OUT sa_link TEXT,
    OUT sa_owner_id UUID,
    OUT sa_location_id UUID,
    OUT sa_root_id UUID
) AS $$
DECLARE
    v_schema        TEXT;
    v_table         TEXT;
    v_parts         TEXT[];
    v_info          claimius.table_info%ROWTYPE;
    v_sql           TEXT;
    v_select_cols   TEXT;
    v_owner_id      UUID;
    v_location_id   UUID;
BEGIN
    v_parts := claimius.split_object_type(p_object_type);
    v_schema := v_parts[1];
    v_table := v_parts[2];

    SELECT * INTO v_info FROM claimius.table_info WHERE object_type = p_object_type;

    IF v_info IS NULL THEN
        RETURN;
    END IF;

    v_select_cols := format(
            '%s, %s, %s, %s, %s',
            CASE WHEN v_info.has_name THEN 'name::TEXT' ELSE 'NULL::TEXT' END,
            CASE WHEN v_info.has_description THEN 'description::TEXT' ELSE 'NULL::TEXT' END,
            CASE WHEN v_info.has_sa_owner_id THEN 'sa_owner_id' ELSE 'NULL::UUID' END,
            CASE WHEN v_info.has_sa_location_id THEN 'sa_location_id' ELSE 'NULL::UUID' END,
            CASE WHEN v_info.has_sa_root_id THEN 'sa_root_id' ELSE 'NULL::UUID' END
                     );

    v_sql := format('SELECT %s FROM %I.%I WHERE id = $1', v_select_cols, v_schema, v_table);
    EXECUTE v_sql INTO sa_name, sa_description, sa_owner_id, sa_location_id, sa_root_id USING p_object_id;

    v_owner_id := sa_owner_id;
    v_location_id := sa_location_id;

    IF sa_root_id IS NULL AND v_owner_id IS NOT NULL THEN
        SELECT o.sa_root_id INTO sa_root_id
        FROM claimius.organization o
        WHERE o.id = v_owner_id;
    END IF;

    IF sa_root_id IS NULL AND v_location_id IS NOT NULL THEN
        SELECT l.sa_root_id INTO sa_root_id
        FROM claimius.location l
        WHERE l.id = v_location_id;
    END IF;

    sa_link := NULL;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claimius._denormalize_object IS 'Reads name/description/owner/location/root from a registered row. Falls back to organization or location sa_root_id when the row carries no sa_root_id column.';

UPDATE claimius.user_object uo
SET sa_root_id = o.sa_root_id
FROM claimius.organization o
WHERE uo.sa_root_id IS NULL
  AND uo.sa_owner_id = o.id;

UPDATE claimius.user_object uo
SET sa_root_id = l.sa_root_id
FROM claimius.location l
WHERE uo.sa_root_id IS NULL
  AND uo.sa_location_id = l.id;
