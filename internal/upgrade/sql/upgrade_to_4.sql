CREATE TABLE IF NOT EXISTS samna_migrate.requirement (
    id         SERIAL PRIMARY KEY,
    kind       TEXT NOT NULL CHECK (kind IN ('extension','language','role')),
    name       TEXT NOT NULL,
    first_seen TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (kind, name)
);
