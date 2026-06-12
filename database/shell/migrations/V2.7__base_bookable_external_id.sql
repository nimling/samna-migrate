ALTER TABLE bookable ADD COLUMN external_id TEXT DEFAULT NULL;
CREATE INDEX IF NOT EXISTS idx_bookable_external_id ON bookable (external_id);
