CREATE TABLE IF NOT EXISTS bookable_type
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text        NOT NULL,
    description   text,
    keywords      text[],
    sa_created_by uuid        NOT NULL REFERENCES claimius.user_claim (id),
    sa_owner_id   uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);


CREATE TABLE IF NOT EXISTS timeslot
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text,
    description   text,
    sa_parent_id  uuid REFERENCES timeslot (id),
    sa_root_id    uuid,
    schedule      jsonb       NOT NULL,
    sa_created_by uuid        NOT NULL REFERENCES claimius.user_claim (id),
    sa_owner_id   uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_timeslot_sa_owner_id ON timeslot (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_timeslot_sa_deleted_at ON timeslot (sa_deleted_at);


CREATE TABLE IF NOT EXISTS asset
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text        NOT NULL,
    description   text,
    mime_type     text        NOT NULL,
    sa_created_by uuid REFERENCES claimius.user_claim (id),
    sa_owner_id   uuid REFERENCES claimius.organization (id),
    status        text        NOT NULL DEFAULT 'pending',
    blob_url      text,
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_asset_sa_owner_id ON asset (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_asset_sa_deleted_at ON asset (sa_deleted_at);


CREATE TABLE IF NOT EXISTS capability
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text        NOT NULL,
    description   text,
    locale        jsonb,
    value         jsonb,
    render        text,
    sa_created_by uuid REFERENCES claimius.user_claim (id),
    sa_owner_id   uuid REFERENCES claimius.organization (id),
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_capability_sa_owner_id ON capability (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_capability_sa_deleted_at ON capability (sa_deleted_at);


CREATE TABLE IF NOT EXISTS bookable
(
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name           text        NOT NULL,
    description    text,
    sa_parent_id   uuid REFERENCES bookable (id),
    sa_root_id     uuid,
    sa_location_id uuid REFERENCES claimius.location (id),
    type_id        uuid REFERENCES bookable_type (id),
    sa_created_by  uuid        NOT NULL REFERENCES claimius.user_claim (id),
    sa_owner_id    uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_deleted_at  timestamptz,
    sa_created_at  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_bookable_sa_location_id ON bookable (sa_location_id);
CREATE INDEX IF NOT EXISTS idx_bookable_sa_owner_id ON bookable (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_bookable_sa_deleted_at ON bookable (sa_deleted_at);
CREATE INDEX IF NOT EXISTS idx_bookable_type_id ON bookable (type_id);


CREATE TABLE IF NOT EXISTS object_timeslot
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reason        text,
    timeslot_id   uuid        NOT NULL REFERENCES timeslot (id),
    object_id     uuid        NOT NULL,
    priority      integer              DEFAULT 0,
    object_type   varchar     NOT NULL,
    conditions    jsonb,
    sa_created_by uuid REFERENCES claimius.user_claim (id),
    sa_owner_id   uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);


CREATE TABLE IF NOT EXISTS checkin
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    starts_at     timestamptz NOT NULL,
    ends_at       timestamptz NOT NULL,
    object_type   varchar     NOT NULL,
    object_id     uuid,
    check_in      timestamptz,
    check_out     timestamptz,
    type          varchar,
    sa_owner_id   uuid REFERENCES claimius.organization (id),
    sa_created_by uuid        NOT NULL,
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_checkin_sa_owner_id ON checkin (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_checkin_starts_at ON checkin (starts_at);
CREATE INDEX IF NOT EXISTS idx_checkin_ends_at ON checkin (ends_at);
CREATE INDEX IF NOT EXISTS idx_checkin_object_id ON checkin (object_id);


CREATE TABLE IF NOT EXISTS booking
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    description   text,
    name          text,
    bookable_id   uuid        NOT NULL REFERENCES bookable (id),
    schedule      jsonb       NOT NULL,
    checkin_id    uuid                 DEFAULT NULL REFERENCES checkin (id),
    sa_created_by uuid        NOT NULL REFERENCES claimius.user_claim (id),
    sa_owner_id   uuid        NOT NULL REFERENCES claimius.organization (id),
    status        text        NOT NULL DEFAULT 'confirmed',
    reserved_at   timestamptz,
    canceled_at   timestamptz,
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_booking_bookable_id ON booking (bookable_id);
CREATE INDEX IF NOT EXISTS idx_booking_checkin_id ON booking (checkin_id);
CREATE INDEX IF NOT EXISTS idx_booking_schedule ON booking USING GIN (schedule);
CREATE INDEX IF NOT EXISTS idx_booking_sa_deleted_at ON booking (sa_deleted_at);
CREATE INDEX IF NOT EXISTS idx_booking_status ON booking (status) WHERE sa_deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_booking_canceled_at ON booking (canceled_at);
CREATE INDEX IF NOT EXISTS idx_booking_reserved_at ON booking (reserved_at);


CREATE TABLE IF NOT EXISTS payment
(
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id        uuid        NOT NULL REFERENCES booking (id),
    user_id           uuid,
    bookable_id       uuid,
    checkin_id        uuid REFERENCES checkin(id),
    status            text        NOT NULL DEFAULT 'pending',
    payment_intent_id text,
    url               text,
    amount            bigint,
    currency          text,
    provider          text        NOT NULL DEFAULT 'stripe',
    used_at           timestamptz,
    sa_created_by     uuid        NOT NULL REFERENCES claimius.user_claim (id),
    sa_owner_id       uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_deleted_at     timestamptz,
    sa_created_at     timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at     timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_payment_booking_id ON payment (booking_id);
CREATE INDEX IF NOT EXISTS idx_payment_sa_owner_id ON payment (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_payment_sa_deleted_at ON payment (sa_deleted_at);
CREATE INDEX IF NOT EXISTS idx_payment_lookup ON payment (user_id, bookable_id, status) WHERE sa_deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_payment_used_at ON payment (used_at) WHERE used_at IS NULL;

CREATE TABLE IF NOT EXISTS object_asset
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id      uuid        NOT NULL REFERENCES asset (id),
    object_id     uuid        NOT NULL,
    object_type   text        NOT NULL,
    index         integer     NOT NULL DEFAULT 0,
    sa_created_by uuid REFERENCES claimius.user_claim (id),
    sa_owner_id   uuid REFERENCES claimius.organization (id),
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_object_asset_object_id ON object_asset (object_id);
CREATE INDEX IF NOT EXISTS idx_object_asset_asset_id ON object_asset (asset_id);
CREATE INDEX IF NOT EXISTS idx_object_asset_sa_deleted_at ON object_asset (sa_deleted_at);


CREATE TABLE IF NOT EXISTS code
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    value         varchar UNIQUE NOT NULL,
    data          jsonb,
    styling       jsonb,
    asset_id      uuid REFERENCES asset (id),
    name          text           NOT NULL,
    description   text,
    sa_created_by uuid           NOT NULL REFERENCES claimius.user_claim (id),
    sa_owner_id   uuid           NOT NULL REFERENCES claimius.organization (id),
    expires_at    timestamptz,
    sa_deleted_at timestamptz,
    sa_created_at timestamptz    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_code_sa_owner_id ON code (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_code_asset_id ON code (asset_id);
CREATE INDEX IF NOT EXISTS idx_code_sa_deleted_at ON code (sa_deleted_at);


CREATE TABLE IF NOT EXISTS feedback
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    message       text        NOT NULL,
    user_id       uuid        NOT NULL,
    object_type   text        NOT NULL,
    object_id     uuid        NOT NULL,
    rating        int         NOT NULL,
    sa_owner_id   uuid REFERENCES claimius.organization (id),
    sa_created_by uuid REFERENCES claimius.user_claim (id),
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_feedback_sa_owner_id ON feedback (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_feedback_user_id ON feedback (user_id);
CREATE INDEX IF NOT EXISTS idx_feedback_sa_deleted_at ON feedback (sa_deleted_at);


CREATE TABLE IF NOT EXISTS object_capability
(
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reason          text,
    capability_id   uuid        NOT NULL REFERENCES capability (id),
    object_id       uuid        NOT NULL,
    priority        int                  DEFAULT 0,
    object_type     text        NOT NULL,
    sa_created_by   uuid REFERENCES claimius.user_claim (id),
    sa_owner_id     uuid REFERENCES claimius.organization (id),
    sa_deleted_at   timestamptz,
    sa_created_at   timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at   timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_object_capability_object_id ON object_capability (object_id);
CREATE INDEX IF NOT EXISTS idx_object_capability_capability_id ON object_capability (capability_id);
CREATE INDEX IF NOT EXISTS idx_object_capability_sa_owner_id ON object_capability (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_object_capability_sa_deleted_at ON object_capability (sa_deleted_at);


CREATE TABLE IF NOT EXISTS setting
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    object_id     uuid        NOT NULL,
    object_type   text        NOT NULL,
    value         jsonb       NOT NULL,
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_setting_object_id ON setting (object_id);
CREATE INDEX IF NOT EXISTS idx_setting_object_type ON setting (object_type);
CREATE INDEX IF NOT EXISTS idx_setting_sa_deleted_at ON setting (sa_deleted_at);


CREATE TABLE IF NOT EXISTS ai_request
(
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    object_type      varchar     NOT NULL,
    object_id        uuid        NOT NULL,
    system_prompt    text        NOT NULL,
    user_prompt      text,
    model_name       text        NOT NULL,
    status           varchar     NOT NULL DEFAULT 'pending',
    progress         integer     NOT NULL DEFAULT 0,
    prediction_id    varchar,
    prediction_error text,
    request_type     varchar     NOT NULL,
    response         text,
    expires_at       timestamptz NOT NULL DEFAULT (CURRENT_TIMESTAMP + INTERVAL '14 days'),
    sa_parent_id     uuid                 DEFAULT NULL REFERENCES ai_request (id) ON DELETE CASCADE,
    sa_root_id       uuid,
    sa_created_by    uuid        NOT NULL REFERENCES claimius.user_claim (id),
    updated_by       uuid        NOT NULL REFERENCES claimius.user_claim (id),
    sa_owner_id      uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_deleted_at    timestamptz,
    sa_created_at    timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at    timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_ai_request_object_type ON ai_request (object_type);
CREATE INDEX IF NOT EXISTS idx_ai_request_object_id ON ai_request (object_id);
CREATE INDEX IF NOT EXISTS idx_ai_request_status ON ai_request (status);
CREATE INDEX IF NOT EXISTS idx_ai_request_expires_at ON ai_request (expires_at);
CREATE INDEX IF NOT EXISTS idx_ai_request_sa_owner_id ON ai_request (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_ai_request_sa_deleted_at ON ai_request (sa_deleted_at);
CREATE INDEX IF NOT EXISTS idx_ai_request_sa_parent_id ON ai_request (sa_parent_id) WHERE sa_parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_ai_request_parent_created ON ai_request (sa_parent_id, sa_created_at DESC) WHERE sa_parent_id IS NOT NULL;


CREATE TABLE IF NOT EXISTS action
(
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name             varchar     NOT NULL,
    description      text,
    trigger          text        NOT NULL,
    code             text        NOT NULL,
    public           boolean     NOT NULL DEFAULT false,
    continue_on_fail boolean     NOT NULL DEFAULT false,
    dedup_mode       text        NOT NULL DEFAULT 'per_attachment',
    sa_created_by    uuid REFERENCES claimius.user_claim (id),
    sa_owner_id      uuid REFERENCES claimius.organization (id),
    input            jsonb       NOT NULL DEFAULT '{}',
    session_id       uuid                 DEFAULT NULL REFERENCES ai_request (id) ON DELETE CASCADE,
    sa_deleted_at    timestamptz,
    sa_created_at    timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at    timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_action_trigger ON action (trigger);
CREATE INDEX IF NOT EXISTS idx_action_sa_owner_id ON action (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_action_public ON action (public);
CREATE INDEX IF NOT EXISTS idx_action_session_id ON action (session_id);
CREATE INDEX IF NOT EXISTS idx_action_sa_deleted_at ON action (sa_deleted_at);


CREATE TABLE IF NOT EXISTS action_object
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reason        text,
    action_id     uuid        NOT NULL REFERENCES action (id),
    object_id     uuid        NOT NULL,
    object_type   varchar     NOT NULL,
    priority      integer     NOT NULL DEFAULT 0,
    input         jsonb       NOT NULL,
    sa_created_by uuid REFERENCES claimius.user_claim (id),
    sa_owner_id   uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_action_object_action_id ON action_object (action_id);
CREATE INDEX IF NOT EXISTS idx_action_object_object_id ON action_object (object_id);
CREATE INDEX IF NOT EXISTS idx_action_object_object_type ON action_object (object_type);
CREATE INDEX IF NOT EXISTS idx_action_object_sa_owner_id ON action_object (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_action_object_sa_deleted_at ON action_object (sa_deleted_at);
CREATE INDEX IF NOT EXISTS idx_action_object_priority ON action_object (object_type, object_id, priority) WHERE sa_deleted_at IS NULL;

CREATE OR REPLACE FUNCTION set_action_object_priority() RETURNS trigger AS $$
BEGIN
    IF NEW.priority IS NULL OR NEW.priority = 0 THEN
        SELECT COALESCE(MAX(priority), 0) + 1 INTO NEW.priority
        FROM action_object
        WHERE object_id = NEW.object_id
          AND object_type = NEW.object_type
          AND sa_deleted_at IS NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_action_object_set_priority ON action_object;
CREATE TRIGGER trg_action_object_set_priority
    BEFORE INSERT ON action_object
    FOR EACH ROW
    EXECUTE FUNCTION set_action_object_priority();


CREATE TABLE IF NOT EXISTS activity
(
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type           varchar     NOT NULL,
    booking_id           uuid REFERENCES booking (id),
    checkin_id           uuid REFERENCES checkin (id),
    code_id              uuid REFERENCES code (id),
    location_id          uuid REFERENCES claimius.location (id),
    bookable_id          uuid REFERENCES bookable (id),
    bookable_type_id     uuid REFERENCES bookable_type (id),
    user_id              uuid,
    organization_id      uuid REFERENCES claimius.organization (id),
    started_at           timestamptz NOT NULL,
    ended_at             timestamptz NOT NULL,
    location             jsonb,
    owner                jsonb,
    samna_user           jsonb,
    bookable             jsonb,
    bookable_type        jsonb,
    checkin              jsonb,
    sa_created_by        uuid REFERENCES claimius.user_claim (id),
    correlation_id       uuid,
    sequence             integer     NOT NULL DEFAULT 0,
    previous_activity_id uuid REFERENCES activity (id),
    sa_owner_id          uuid REFERENCES claimius.organization (id),
    sa_deleted_at        timestamptz          DEFAULT NULL,
    sa_created_at        timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at        timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_activity_event_type ON activity (event_type);
CREATE INDEX IF NOT EXISTS idx_activity_booking_id ON activity (booking_id);
CREATE INDEX IF NOT EXISTS idx_activity_checkin_id ON activity (checkin_id);
CREATE INDEX IF NOT EXISTS idx_activity_location_id ON activity (location_id);
CREATE INDEX IF NOT EXISTS idx_activity_bookable_id ON activity (bookable_id);
CREATE INDEX IF NOT EXISTS idx_activity_bookable_type_id ON activity (bookable_type_id);
CREATE INDEX IF NOT EXISTS idx_activity_user_id ON activity (user_id);
CREATE INDEX IF NOT EXISTS idx_activity_organization_id ON activity (organization_id);
CREATE INDEX IF NOT EXISTS idx_activity_started_at ON activity (started_at);
CREATE INDEX IF NOT EXISTS idx_activity_sa_deleted_at ON activity (sa_deleted_at);
CREATE INDEX IF NOT EXISTS idx_activity_sa_owner_id ON activity (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_activity_ended_at ON activity (ended_at);
CREATE INDEX IF NOT EXISTS idx_activity_correlation_id ON activity (correlation_id);
CREATE INDEX IF NOT EXISTS idx_activity_sa_owner_id ON activity (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_activity_sa_created_by ON activity (sa_created_by);
CREATE INDEX IF NOT EXISTS idx_activity_sa_created_at ON activity (sa_created_at);


CREATE TABLE IF NOT EXISTS search_index (
    "object_id"     UUID NOT NULL,
    "object_type"   TEXT NOT NULL,
    "search_vector" TSVECTOR NOT NULL,
    PRIMARY KEY (object_id, object_type)
);

CREATE INDEX IF NOT EXISTS idx_search_index_vector ON search_index USING GIN (search_vector);


CREATE TABLE IF NOT EXISTS calendar_plan
(
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    status           text        NOT NULL,
    wish             text        NOT NULL,
    user_ids         uuid[],
    bookable_ids     uuid[],
    entries          jsonb       NOT NULL,
    ai_request       uuid        NOT NULL REFERENCES ai_request (id),
    sa_created_by    uuid        NOT NULL REFERENCES claimius.user_claim (id),
    sa_owner_id      uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_deleted_at    timestamptz,
    sa_created_at    timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at    timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);


CREATE TABLE IF NOT EXISTS event_webhook
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    url           text        NOT NULL,
    event_name    varchar,
    secret        text        NOT NULL,
    active        boolean     NOT NULL DEFAULT TRUE,
    sa_owner_id   uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_created_by uuid REFERENCES claimius.user_claim (id),
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_event_webhook_owner_id ON event_webhook (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_event_webhook_event_name ON event_webhook (event_name);
CREATE INDEX IF NOT EXISTS idx_event_webhook_active ON event_webhook (active) WHERE sa_deleted_at IS NULL;


CREATE TABLE IF NOT EXISTS event_func
(
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text        NOT NULL,
    url           text        NOT NULL,
    secret        text        NOT NULL,
    active        boolean     NOT NULL DEFAULT TRUE,
    sa_owner_id   uuid        NOT NULL REFERENCES claimius.organization (id),
    sa_created_by uuid REFERENCES claimius.user_claim (id),
    sa_deleted_at timestamptz,
    sa_created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sa_updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_event_func_name_owner ON event_func (name, sa_owner_id) WHERE sa_deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_event_func_owner_id ON event_func (sa_owner_id);
CREATE INDEX IF NOT EXISTS idx_event_func_active ON event_func (active) WHERE sa_deleted_at IS NULL;


CREATE OR REPLACE FUNCTION notify_activity_change()
    RETURNS TRIGGER AS
$$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM pg_notify('activity_event', json_build_object(
                'event_type', NEW.event_type,
                'activity_id', NEW.id,
                'booking_id', NEW.booking_id,
                'checkin_id', NEW.checkin_id,
                'location_id', NEW.location_id,
                'bookable_id', NEW.bookable_id,
                'bookable_type_id', NEW.bookable_type_id,
                'user_id', NEW.user_id,
                'organization_id', NEW.organization_id,
                'sa_owner_id', NEW.sa_owner_id
                                            )::text);
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS activity_change_trigger ON activity;
CREATE TRIGGER activity_change_trigger
    AFTER INSERT
    ON activity
    FOR EACH ROW
EXECUTE FUNCTION notify_activity_change();
