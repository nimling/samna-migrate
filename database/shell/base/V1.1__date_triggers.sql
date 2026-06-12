CREATE OR REPLACE FUNCTION update_current_timestamp()
RETURNS TRIGGER AS $$
BEGIN
   NEW.sa_updated_at = CURRENT_TIMESTAMP;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
BEFORE UPDATE ON bookable
FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON bookable_type
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
BEFORE UPDATE ON booking
FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON timeslot
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON object_timeslot
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON code
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON checkin
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON asset
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON object_asset
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON setting
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON capability
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON object_capability
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON action
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON action_object
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON ai_request
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON event_webhook
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();

CREATE OR REPLACE TRIGGER update_current_timestamp_before_update
    BEFORE UPDATE ON event_func
    FOR EACH ROW
EXECUTE FUNCTION update_current_timestamp();
