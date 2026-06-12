DROP TRIGGER IF EXISTS tr_checkin_activity ON checkin;
DROP TRIGGER IF EXISTS tr_update_booking_on_checkin_change ON checkin;
DROP FUNCTION IF EXISTS create_checkin_activity();
DROP FUNCTION IF EXISTS update_booking_on_checkin_change();

ALTER TABLE checkin
    ADD COLUMN IF NOT EXISTS checkin_window     jsonb       DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS checkout_window    jsonb       DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS checkin_required   boolean     NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS checkout_required  boolean     NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS require_all        boolean     NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS inherits           boolean     NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS schedule           jsonb       DEFAULT NULL;

CREATE TABLE IF NOT EXISTS object_checkin
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    checkin_id    uuid        NOT NULL REFERENCES checkin (id),
    booking_id    uuid        NOT NULL REFERENCES booking (id),
    user_id       uuid        NOT NULL,
    checkin_at    timestamptz DEFAULT NULL,
    checkout_at   timestamptz DEFAULT NULL,
    sa_owner_id   uuid REFERENCES claimius.organization (id),
    sa_created_by uuid        NOT NULL,
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

DO $$
DECLARE
    has_check_in   boolean;
    has_check_out  boolean;
    has_starts_at  boolean;
    has_ends_at    boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'checkin' AND column_name = 'check_in')   INTO has_check_in;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'checkin' AND column_name = 'check_out')  INTO has_check_out;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'checkin' AND column_name = 'starts_at')  INTO has_starts_at;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'checkin' AND column_name = 'ends_at')    INTO has_ends_at;

    IF has_check_in AND has_check_out THEN
        EXECUTE $sql$
            INSERT INTO object_checkin (checkin_id, booking_id, user_id, checkin_at, checkout_at, sa_owner_id, sa_created_by)
            SELECT
                c.id,
                b.id,
                uc.user_id,
                c.check_in,
                c.check_out,
                c.sa_owner_id,
                c.sa_created_by
            FROM checkin c
            JOIN booking b ON b.checkin_id = c.id AND b.sa_deleted_at IS NULL
            JOIN claimius.user_claim uc ON uc.id = b.sa_created_by
            WHERE c.sa_deleted_at IS NULL
              AND (c.check_in IS NOT NULL OR c.check_out IS NOT NULL)
            ON CONFLICT DO NOTHING
        $sql$;
    END IF;

    IF has_starts_at AND has_ends_at THEN
        EXECUTE $sql$
            UPDATE checkin c
            SET checkin_window = jsonb_build_object(
                    'from', GREATEST(0, EXTRACT(EPOCH FROM (b.schedule_start - c.starts_at))::int / 60),
                    'to',   GREATEST(0, EXTRACT(EPOCH FROM (c.ends_at - b.schedule_start))::int / 60)
                )
            FROM (
                SELECT bk.checkin_id,
                       COALESCE(
                           NULLIF(bk.schedule->>'start_date','')::timestamptz,
                           (bk.schedule->0->>'start_date')::timestamptz
                       ) AS schedule_start
                FROM booking bk
                WHERE bk.sa_deleted_at IS NULL
                  AND bk.checkin_id IS NOT NULL
            ) b
            WHERE c.id = b.checkin_id
              AND c.sa_deleted_at IS NULL
              AND c.starts_at IS NOT NULL
              AND c.ends_at IS NOT NULL
              AND b.schedule_start IS NOT NULL
              AND c.checkin_window IS NULL
        $sql$;
    END IF;
END $$;

ALTER TABLE checkin
    DROP COLUMN IF EXISTS starts_at,
    DROP COLUMN IF EXISTS ends_at,
    DROP COLUMN IF EXISTS check_in,
    DROP COLUMN IF EXISTS check_out,
    DROP COLUMN IF EXISTS type;

ALTER TABLE checkin
    DROP CONSTRAINT IF EXISTS checkin_window_is_object,
    DROP CONSTRAINT IF EXISTS checkout_window_is_object,
    DROP CONSTRAINT IF EXISTS checkin_schedule_is_array;
ALTER TABLE checkin
    ADD CONSTRAINT checkin_window_is_object     CHECK (checkin_window IS NULL OR jsonb_typeof(checkin_window) = 'object'),
    ADD CONSTRAINT checkout_window_is_object    CHECK (checkout_window IS NULL OR jsonb_typeof(checkout_window) = 'object'),
    ADD CONSTRAINT checkin_schedule_is_array    CHECK (schedule IS NULL OR jsonb_typeof(schedule) = 'array');

DROP INDEX IF EXISTS idx_checkin_starts_at;
DROP INDEX IF EXISTS idx_checkin_ends_at;
CREATE INDEX IF NOT EXISTS idx_checkin_object_type ON checkin (object_type);
CREATE INDEX IF NOT EXISTS idx_checkin_inherits ON checkin (inherits);

CREATE UNIQUE INDEX IF NOT EXISTS idx_object_checkin_unique
    ON object_checkin (checkin_id, booking_id, user_id)
    WHERE sa_deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_object_checkin_checkin_id ON object_checkin (checkin_id);
CREATE INDEX IF NOT EXISTS idx_object_checkin_booking_id ON object_checkin (booking_id);
CREATE INDEX IF NOT EXISTS idx_object_checkin_user_id ON object_checkin (user_id);
CREATE INDEX IF NOT EXISTS idx_object_checkin_sa_owner_id ON object_checkin (sa_owner_id);

SELECT claimius.init_claimius_tables(
    'public.bookable',
    'public.bookable_type',
    'public.booking',
    'public.checkin',
    'public.object_checkin',
    'public.timeslot',
    'public.object_timeslot',
    'public.asset',
    'public.object_asset',
    'public.code',
    'public.capability',
    'public.object_capability',
    'public.action',
    'public.action_object',
    'public.ai_request',
    'public.feedback',
    'public.activity',
    'public.event_webhook',
    'public.event_func',
    'public.payment',
    'public.calendar_plan'
);
