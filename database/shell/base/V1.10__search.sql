CREATE OR REPLACE FUNCTION tg_search_index()
RETURNS TRIGGER AS $$
DECLARE
    v_vector TSVECTOR;
BEGIN
    IF TG_OP = 'DELETE' THEN
        DELETE FROM search_index
        WHERE object_id = OLD.id AND object_type = TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
        RETURN OLD;
    END IF;

    v_vector := setweight(to_tsvector('english', COALESCE(NEW.name, '')), 'A') ||
                setweight(to_tsvector('english', COALESCE(NEW.description, '')), 'B');

    INSERT INTO search_index (object_id, object_type, search_vector)
    VALUES (NEW.id, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_vector)
    ON CONFLICT (object_id, object_type) DO UPDATE
    SET search_vector = EXCLUDED.search_vector;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER search_index_bookable
    AFTER INSERT OR UPDATE OR DELETE ON bookable
    FOR EACH ROW EXECUTE FUNCTION tg_search_index();

CREATE OR REPLACE TRIGGER search_index_booking
    AFTER INSERT OR UPDATE OR DELETE ON booking
    FOR EACH ROW EXECUTE FUNCTION tg_search_index();

CREATE OR REPLACE TRIGGER search_index_timeslot
    AFTER INSERT OR UPDATE OR DELETE ON timeslot
    FOR EACH ROW EXECUTE FUNCTION tg_search_index();

CREATE OR REPLACE TRIGGER search_index_bookable_type
    AFTER INSERT OR UPDATE OR DELETE ON bookable_type
    FOR EACH ROW EXECUTE FUNCTION tg_search_index();

CREATE OR REPLACE TRIGGER search_index_capability
    AFTER INSERT OR UPDATE OR DELETE ON capability
    FOR EACH ROW EXECUTE FUNCTION tg_search_index();

CREATE OR REPLACE TRIGGER search_index_asset
    AFTER INSERT OR UPDATE OR DELETE ON asset
    FOR EACH ROW EXECUTE FUNCTION tg_search_index();

CREATE OR REPLACE TRIGGER search_index_code
    AFTER INSERT OR UPDATE OR DELETE ON code
    FOR EACH ROW EXECUTE FUNCTION tg_search_index();
