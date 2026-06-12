ALTER TABLE bookable_type ADD COLUMN external_id TEXT DEFAULT NULL;
CREATE INDEX IF NOT EXISTS idx_bookable_type_external_id ON bookable_type (external_id);
