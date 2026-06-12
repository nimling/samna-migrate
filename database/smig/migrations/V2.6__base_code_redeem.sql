ALTER TABLE code ADD COLUMN count integer NOT NULL DEFAULT 0;
ALTER TABLE code ADD COLUMN redeemed_count integer NOT NULL DEFAULT 0;
ALTER TABLE code ADD COLUMN redeemed_at timestamptz;
ALTER TABLE code ADD COLUMN starts_at timestamptz;
ALTER TABLE code ADD COLUMN ends_at timestamptz;
