ALTER TABLE booking
    DROP CONSTRAINT IF EXISTS booking_schedule_is_array,
    DROP CONSTRAINT IF EXISTS booking_cancellation_is_array;
ALTER TABLE timeslot
    DROP CONSTRAINT IF EXISTS timeslot_schedule_is_array;
ALTER TABLE checkin
    DROP CONSTRAINT IF EXISTS checkin_schedule_is_array;

CREATE OR REPLACE FUNCTION normalize_jsonb_array_columns() RETURNS TRIGGER AS $$
BEGIN
    IF TG_TABLE_NAME = 'booking' THEN
        IF NEW.schedule IS NOT NULL AND jsonb_typeof(NEW.schedule) <> 'array' THEN
            NEW.schedule := jsonb_build_array(NEW.schedule);
        END IF;
        IF NEW.cancellation IS NOT NULL AND jsonb_typeof(NEW.cancellation) <> 'array' THEN
            NEW.cancellation := jsonb_build_array(NEW.cancellation);
        END IF;
    ELSIF TG_TABLE_NAME = 'timeslot' THEN
        IF NEW.schedule IS NOT NULL AND jsonb_typeof(NEW.schedule) <> 'array' THEN
            NEW.schedule := jsonb_build_array(NEW.schedule);
        END IF;
    ELSIF TG_TABLE_NAME = 'checkin' THEN
        IF NEW.schedule IS NOT NULL AND jsonb_typeof(NEW.schedule) <> 'array' THEN
            NEW.schedule := jsonb_build_array(NEW.schedule);
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tr_normalize_booking_arrays ON booking;
CREATE TRIGGER tr_normalize_booking_arrays
    BEFORE INSERT OR UPDATE ON booking
    FOR EACH ROW EXECUTE FUNCTION normalize_jsonb_array_columns();

DROP TRIGGER IF EXISTS tr_normalize_timeslot_arrays ON timeslot;
CREATE TRIGGER tr_normalize_timeslot_arrays
    BEFORE INSERT OR UPDATE ON timeslot
    FOR EACH ROW EXECUTE FUNCTION normalize_jsonb_array_columns();

DROP TRIGGER IF EXISTS tr_normalize_checkin_arrays ON checkin;
CREATE TRIGGER tr_normalize_checkin_arrays
    BEFORE INSERT OR UPDATE ON checkin
    FOR EACH ROW EXECUTE FUNCTION normalize_jsonb_array_columns();

ALTER TABLE booking
    ADD CONSTRAINT booking_schedule_is_array     CHECK (jsonb_typeof(schedule) = 'array'),
    ADD CONSTRAINT booking_cancellation_is_array CHECK (cancellation IS NULL OR jsonb_typeof(cancellation) = 'array');
ALTER TABLE timeslot
    ADD CONSTRAINT timeslot_schedule_is_array CHECK (jsonb_typeof(schedule) = 'array');
ALTER TABLE checkin
    ADD CONSTRAINT checkin_schedule_is_array CHECK (schedule IS NULL OR jsonb_typeof(schedule) = 'array');

ALTER TABLE checkin
    ADD COLUMN IF NOT EXISTS starts_at  timestamptz,
    ADD COLUMN IF NOT EXISTS ends_at    timestamptz,
    ADD COLUMN IF NOT EXISTS check_in   timestamptz,
    ADD COLUMN IF NOT EXISTS check_out  timestamptz,
    ADD COLUMN IF NOT EXISTS type       text;
