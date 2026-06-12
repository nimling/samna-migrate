ALTER TABLE code ADD COLUMN object_id uuid;
ALTER TABLE code ADD COLUMN object_type text;

ALTER TABLE code
    ADD CONSTRAINT code_object_link_both_or_neither
    CHECK ((object_id IS NULL) = (object_type IS NULL));
