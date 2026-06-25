BEGIN;

-- Enum types
CREATE TYPE end_device_device_type AS ENUM ('direct_der', 'aggregator');
CREATE TYPE end_device_registration_state AS ENUM ('pending', 'registered', 'rejected', 'inactive', 'deleted');
CREATE TYPE connection_point_connection_status AS ENUM ('connected', 'disconnected');
CREATE TYPE mirror_usage_point_status AS ENUM ('active', 'inactive', 'expired');
CREATE TYPE mirror_meter_reading_quality AS ENUM ('valid', 'estimated', 'missing', 'questionable');
CREATE TYPE time_resource_quality AS ENUM ('authoritative', 'level_3', 'level_4', 'level_5', 'level_6', 'inaccurate');
CREATE TYPE acl_entry_method AS ENUM ('get', 'post', 'put', 'delete', 'head');
CREATE TYPE acl_entry_auth_type AS ENUM ('certificate', 'pin', 'none');
CREATE TYPE acl_entry_device_type_filter AS ENUM ('direct_der', 'aggregator', 'any');

CREATE TABLE end_device (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    lfdi TEXT NOT NULL UNIQUE,
    sfdi TEXT NOT NULL,
    device_type end_device_device_type NOT NULL,  -- direct-der, aggregator
    pin NUMERIC,
    enabled BOOLEAN DEFAULT TRUE,
    registration_state end_device_registration_state DEFAULT 'pending',  -- pending, registered, rejected, inactive, deleted
    changed_time NUMERIC NOT NULL,
    created_time NUMERIC NOT NULL,
    post_rate NUMERIC DEFAULT 900,
    CONSTRAINT lfdi_length CHECK (length(lfdi) = 40),
    CONSTRAINT sfdi_length CHECK (length(sfdi) = 5),
    CONSTRAINT created_before_changed CHECK (created_time <= changed_time),
    CONSTRAINT post_rate_positive CHECK (post_rate > 0),
    CONSTRAINT disabled_when_deleted CHECK ((NOT (registration_state = 'deleted') OR (NOT (enabled)))),
    CONSTRAINT disabled_when_inactive CHECK ((NOT (registration_state = 'inactive') OR (NOT (enabled))))
);

CREATE TABLE connection_point (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    nmi TEXT,
    connection_status connection_point_connection_status DEFAULT 'connected',  -- connected, disconnected
    end_device_id TEXT REFERENCES end_device(id)
);

CREATE TABLE device_capability (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    poll_rate NUMERIC DEFAULT 900,
    end_device_list_link BOOLEAN DEFAULT TRUE,
    mirror_usage_point_list_link BOOLEAN DEFAULT TRUE,
    time_link BOOLEAN DEFAULT TRUE,
    der_program_list_link BOOLEAN,
    self_device_link BOOLEAN DEFAULT TRUE,
    CONSTRAINT dcap_must_have_enddevice_list CHECK (end_device_list_link),
    CONSTRAINT poll_rate_positive CHECK (poll_rate > 0)
);

CREATE TABLE mirror_usage_point (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    mrid TEXT NOT NULL UNIQUE,
    description TEXT,
    role_flags NUMERIC DEFAULT 0,
    status mirror_usage_point_status DEFAULT 'active',  -- active, inactive, expired
    created_time NUMERIC NOT NULL,
    changed_time NUMERIC NOT NULL,
    last_update_time NUMERIC,
    timeout_seconds NUMERIC DEFAULT 259200,
    end_device_id TEXT REFERENCES end_device(id),
    CONSTRAINT mup_created_before_changed CHECK (created_time <= changed_time),
    CONSTRAINT mup_timeout_positive CHECK (timeout_seconds > 0),
    CONSTRAINT mup_role_flags_non_negative CHECK (role_flags >= 0)
);

CREATE TABLE mirror_meter_reading (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    mrid TEXT NOT NULL,
    description TEXT,
    reading_type TEXT,
    value NUMERIC,
    time_stamp NUMERIC NOT NULL,
    quality mirror_meter_reading_quality DEFAULT 'valid',  -- valid, estimated, missing, questionable
    created_time NUMERIC NOT NULL,
    mirror_usage_point_id TEXT REFERENCES mirror_usage_point(id),
    CONSTRAINT reading_timestamp_before_created CHECK (time_stamp <= created_time)
);

CREATE TABLE time_resource (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    current_time NUMERIC NOT NULL,
    quality time_resource_quality DEFAULT 'level_3',  -- authoritative, level-3, level-4, level-5, level-6, inaccurate
    local_offset NUMERIC DEFAULT 0,
    dst_offset NUMERIC DEFAULT 0,
    dst_start NUMERIC DEFAULT 0,
    dst_end NUMERIC DEFAULT 0,
    CONSTRAINT time_positive CHECK (current_time > 0),
    CONSTRAINT dst_window_valid CHECK ((NOT ((dst_start > 0 AND dst_end > 0)) OR (dst_start <= dst_end)))
);

CREATE TABLE acl_entry (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    target_lfdi TEXT NOT NULL,
    resource_path TEXT NOT NULL,
    method acl_entry_method NOT NULL,  -- get, post, put, delete, head
    auth_type acl_entry_auth_type DEFAULT 'certificate',  -- certificate, pin, none
    device_type_filter acl_entry_device_type_filter DEFAULT 'any',  -- direct-der, aggregator, any
    allowed BOOLEAN DEFAULT TRUE,
    CONSTRAINT acl_target_lfdi_length CHECK (length(target_lfdi) = 40)
);

CREATE INDEX idx_end_device_registration_state ON end_device(registration_state);
CREATE INDEX idx_connection_point_end_device ON connection_point(end_device_id);
CREATE INDEX idx_mirror_usage_point_end_device ON mirror_usage_point(end_device_id);
CREATE INDEX idx_mirror_usage_point_status ON mirror_usage_point(status);
CREATE INDEX idx_mirror_meter_reading_mirror_usage_point ON mirror_meter_reading(mirror_usage_point_id);

CREATE OR REPLACE FUNCTION check_end_device_registration_state_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.registration_state = NEW.registration_state THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.registration_state = 'pending' AND NEW.registration_state = 'registered') OR
        (OLD.registration_state = 'pending' AND NEW.registration_state = 'rejected') OR
        (OLD.registration_state = 'registered' AND NEW.registration_state = 'inactive') OR
        (OLD.registration_state = 'inactive' AND NEW.registration_state = 'registered') OR
        (OLD.registration_state = 'registered' AND NEW.registration_state = 'deleted') OR
        (OLD.registration_state = 'inactive' AND NEW.registration_state = 'deleted')
    ) THEN
        RAISE EXCEPTION 'invalid end_device transition: % → %', OLD.registration_state, NEW.registration_state;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_end_device_registration_state
    BEFORE UPDATE OF registration_state ON end_device
    FOR EACH ROW EXECUTE FUNCTION check_end_device_registration_state_transition();

CREATE OR REPLACE FUNCTION check_mirror_usage_point_status_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.status = 'active' AND NEW.status = 'expired') OR
        (OLD.status = 'active' AND NEW.status = 'inactive') OR
        (OLD.status = 'inactive' AND NEW.status = 'active')
    ) THEN
        RAISE EXCEPTION 'invalid mirror_usage_point transition: % → %', OLD.status, NEW.status;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mirror_usage_point_status
    BEFORE UPDATE OF status ON mirror_usage_point
    FOR EACH ROW EXECUTE FUNCTION check_mirror_usage_point_status_transition();

COMMIT;
