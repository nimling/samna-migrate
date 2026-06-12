CREATE OR REPLACE FUNCTION is_schedule_blocked_in_time_range(
    p_set jsonb,
    p_start timestamptz,
    p_end timestamptz
) RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    entry jsonb;
BEGIN
    IF p_set IS NULL OR jsonb_array_length(p_set) = 0 THEN
        RETURN FALSE;
    END IF;
    FOR entry IN SELECT value FROM jsonb_array_elements(p_set) LOOP
        IF NOT COALESCE((entry->>'available')::boolean, TRUE)
           AND _is_schedule_entry_in_time_range(entry, p_start, p_end) THEN
            RETURN TRUE;
        END IF;
    END LOOP;
    RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION schedule_blocked_overlaps_range(
    p_set jsonb,
    p_start timestamptz,
    p_end timestamptz
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(COALESCE(p_set, '[]'::jsonb)) e
        WHERE NOT COALESCE((e->>'available')::boolean, TRUE)
          AND (e->>'start_date')::timestamptz <= p_end
          AND (e->>'end_date' IS NULL OR (e->>'end_date')::timestamptz >= p_start)
    )
$$;

CREATE OR REPLACE FUNCTION booking_blocked_overlaps_range(
    p_booking_id uuid,
    p_start timestamptz,
    p_end timestamptz
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT schedule_blocked_overlaps_range(b.schedule, p_start, p_end)
    FROM booking b
    WHERE b.id = p_booking_id AND b.sa_deleted_at IS NULL
$$;
