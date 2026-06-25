BEGIN;

-- Enum types
CREATE TYPE end_device_device_type AS ENUM ('der', 'aggregator');
CREATE TYPE end_device_lifecycle AS ENUM ('active', 'soft_deleted', 'hard_deleted');
CREATE TYPE end_device_registered_via AS ENUM ('in_band', 'out_of_band');
CREATE TYPE der_control_event_status AS ENUM ('scheduled', 'active', 'cancelled', 'superseded', 'completed');
CREATE TYPE response_status AS ENUM ('received', 'started', 'completed', 'opt_out', 'opt_in', 'cancelled', 'superseded', 'partial_opt_out', 'partial_opt_in', 'no_participation', 'acknowledged', 'rejected_not_applicable', 'rejected_invalid', 'rejected_expired');
CREATE TYPE subscription_lifecycle AS ENUM ('active', 'expired', 'terminated');

-- Config
CREATE TABLE config (
    key   TEXT    PRIMARY KEY,
    value NUMERIC NOT NULL
);

INSERT INTO config (key, value) VALUES
    ('inactivity_threshold_days', 30),  -- [1, 365]
    ('soft_delete_notification_hours', 24),  -- [1, 168]
    ('inband_registration_direct', 1),
    ('inband_registration_aggregator', 1),
    ('subscription_max_per_client', 10),  -- [1, 100]
    ('subscription_expiry_hours', 36),  -- [1, 168]
    ('notification_rate_limit_seconds', 30),  -- [1, 300]
    ('max_groups_per_device', 15),  -- [1, 15]
    ('default_poll_rate_seconds', 300),  -- [60, 86400]
    ('event_retention_margin_hours', 24),  -- [1, 168]
    ('max_list_limit', 250);  -- [1, 10000]

CREATE TABLE end_device (
    id TEXT PRIMARY KEY,
    lfdi TEXT NOT NULL UNIQUE,
    sfdi TEXT NOT NULL,
    device_type end_device_device_type NOT NULL,  -- der, aggregator
    enabled BOOLEAN DEFAULT TRUE,
    lifecycle end_device_lifecycle DEFAULT 'active',  -- active, soft_deleted, hard_deleted
    changed_time NUMERIC NOT NULL,
    last_interaction_time NUMERIC NOT NULL,
    soft_deletion_time NUMERIC DEFAULT 0,
    registered_via end_device_registered_via NOT NULL,  -- in_band, out_of_band
    end_device_id TEXT REFERENCES end_device(id),
    CONSTRAINT lfdi_length CHECK (length(lfdi) = 40),
    CONSTRAINT sfdi_length CHECK (length(sfdi) = 12),
    CONSTRAINT soft_deleted_means_disabled CHECK ((NOT (lifecycle = 'soft_deleted') OR (NOT (enabled)))),
    CONSTRAINT active_means_enabled CHECK ((NOT (lifecycle = 'active') OR (enabled))),
    CONSTRAINT soft_deletion_time_when_soft_deleted CHECK ((NOT (lifecycle = 'soft_deleted') OR (soft_deletion_time > 0))),
    CONSTRAINT changed_time_positive CHECK (changed_time > 0),
    CONSTRAINT last_interaction_positive CHECK (last_interaction_time > 0)
);

CREATE TABLE registration (
    id TEXT PRIMARY KEY,
    pin TEXT DEFAULT '',
    date_time NUMERIC NOT NULL,
    end_device_id TEXT REFERENCES end_device(id),
    CONSTRAINT registration_datetime_positive CHECK (date_time > 0)
);

CREATE TABLE connection_point (
    id TEXT PRIMARY KEY,
    connection_point_id TEXT NOT NULL,
    updated_time NUMERIC NOT NULL,
    end_device_id TEXT REFERENCES end_device(id),
    CONSTRAINT connection_point_id_non_empty CHECK (length(connection_point_id) > 0)
);

CREATE TABLE der_program (
    id TEXT PRIMARY KEY,
    mrid TEXT NOT NULL UNIQUE,
    description TEXT DEFAULT '',
    primacy NUMERIC NOT NULL,
    changed_time NUMERIC NOT NULL,
    poll_rate NUMERIC NOT NULL,
    CONSTRAINT primacy_range CHECK ((primacy >= 0 AND primacy <= 255)),
    CONSTRAINT poll_rate_positive CHECK (poll_rate > 0)
);

CREATE TABLE function_set_assignment (
    id TEXT PRIMARY KEY,
    mrid TEXT NOT NULL UNIQUE,
    description TEXT DEFAULT '',
    changed_time NUMERIC NOT NULL,
    program_count NUMERIC NOT NULL,
    end_device_id TEXT REFERENCES end_device(id),
    CONSTRAINT fsa_program_count_positive CHECK (program_count >= 1)
);

CREATE TABLE der_program_ref (
    id TEXT PRIMARY KEY,
    function_set_assignment_id TEXT REFERENCES function_set_assignment(id),
    der_program_id TEXT REFERENCES der_program(id)
);

CREATE TABLE default_der_control (
    id TEXT PRIMARY KEY,
    mrid TEXT NOT NULL UNIQUE,
    op_mod_max_lim_w NUMERIC DEFAULT 0,
    op_mod_fixed_pf NUMERIC DEFAULT 0,
    set_grad_w NUMERIC DEFAULT 0,
    set_soft_grad_w NUMERIC DEFAULT 0,
    changed_time NUMERIC NOT NULL,
    der_program_id TEXT REFERENCES der_program(id),
    CONSTRAINT default_control_changed_time_positive CHECK (changed_time > 0),
    CONSTRAINT default_control_max_lim_w_non_negative CHECK (op_mod_max_lim_w >= 0)
);

CREATE TABLE der_control (
    id TEXT PRIMARY KEY,
    mrid TEXT NOT NULL UNIQUE,
    description TEXT DEFAULT '',
    creation_time NUMERIC NOT NULL,
    interval_start NUMERIC NOT NULL,
    interval_duration NUMERIC NOT NULL,
    randomize_start NUMERIC DEFAULT 0,
    randomize_duration NUMERIC DEFAULT 0,
    event_status der_control_event_status DEFAULT 'scheduled',  -- scheduled, active, cancelled, superseded, completed
    potentially_superseded BOOLEAN,
    potentially_superseded_time NUMERIC DEFAULT 0,
    op_mod_max_lim_w NUMERIC DEFAULT 0,
    op_mod_connect BOOLEAN DEFAULT TRUE,
    op_mod_energize BOOLEAN DEFAULT TRUE,
    response_required BOOLEAN DEFAULT TRUE,
    der_program_id TEXT REFERENCES der_program(id),
    CONSTRAINT control_interval_positive CHECK (interval_duration > 0),
    CONSTRAINT control_creation_time_positive CHECK (creation_time > 0),
    CONSTRAINT control_start_positive CHECK (interval_start > 0),
    CONSTRAINT superseded_flag_consistency CHECK ((NOT (event_status = 'superseded') OR (potentially_superseded))),
    CONSTRAINT superseded_time_consistency CHECK ((CASE WHEN potentially_superseded THEN (potentially_superseded_time > 0) ELSE (potentially_superseded_time = 0) END))
);

CREATE TABLE der_curve (
    id TEXT PRIMARY KEY,
    mrid TEXT NOT NULL UNIQUE,
    description TEXT DEFAULT '',
    creation_time NUMERIC NOT NULL,
    curve_type NUMERIC NOT NULL,
    x_multiplier NUMERIC DEFAULT 0,
    y_multiplier NUMERIC DEFAULT 0,
    y_ref_type NUMERIC NOT NULL,
    point_count NUMERIC NOT NULL,
    event_status der_control_event_status DEFAULT 'scheduled',  -- scheduled, active, cancelled, superseded, completed
    interval_start NUMERIC NOT NULL,
    interval_duration NUMERIC NOT NULL,
    der_program_id TEXT REFERENCES der_program(id),
    CONSTRAINT curve_min_points CHECK (point_count >= 2),
    CONSTRAINT curve_type_valid CHECK ((curve_type >= 0 AND curve_type <= 12)),
    CONSTRAINT curve_interval_positive CHECK (interval_duration > 0)
);

CREATE TABLE response (
    id TEXT PRIMARY KEY,
    subject_mrid TEXT NOT NULL,
    status response_status NOT NULL,  -- received, started, completed, opt_out, opt_in, cancelled, superseded, partial_opt_out, partial_opt_in, no_participation, acknowledged, rejected_not_applicable, rejected_invalid, rejected_expired
    created_date_time NUMERIC NOT NULL,
    end_device_id TEXT REFERENCES end_device(id)
);

CREATE TABLE subscription (
    id TEXT PRIMARY KEY,
    subscribed_resource_uri TEXT NOT NULL,
    notify_uri TEXT NOT NULL,
    lifecycle subscription_lifecycle DEFAULT 'active',  -- active, expired, terminated
    last_renewal_time NUMERIC NOT NULL,
    created_time NUMERIC NOT NULL,
    last_notification_time NUMERIC DEFAULT 0,
    end_device_id TEXT REFERENCES end_device(id),
    CONSTRAINT subscription_renewal_positive CHECK (last_renewal_time > 0),
    CONSTRAINT subscription_created_positive CHECK (created_time > 0),
    CONSTRAINT subscription_renewal_after_creation CHECK (last_renewal_time >= created_time)
);

CREATE TABLE mirror_usage_point (
    id TEXT PRIMARY KEY,
    mrid TEXT NOT NULL UNIQUE,
    service_category NUMERIC DEFAULT 0,
    created_time NUMERIC NOT NULL,
    last_post_time NUMERIC NOT NULL,
    reading_count NUMERIC DEFAULT 0,
    end_device_id TEXT REFERENCES end_device(id),
    CONSTRAINT mup_reading_count_non_negative CHECK (reading_count >= 0),
    CONSTRAINT mup_last_post_positive CHECK (last_post_time > 0)
);

CREATE TABLE log_event (
    id TEXT PRIMARY KEY,
    mrid TEXT NOT NULL UNIQUE,
    created_time NUMERIC NOT NULL,
    function_set NUMERIC NOT NULL,
    log_event_code NUMERIC NOT NULL,
    log_event_id NUMERIC NOT NULL,
    profile_id NUMERIC DEFAULT 0,
    end_device_id TEXT REFERENCES end_device(id),
    CONSTRAINT log_event_time_positive CHECK (created_time > 0)
);

CREATE INDEX idx_end_device_end_device ON end_device(end_device_id);
CREATE INDEX idx_end_device_lifecycle ON end_device(lifecycle);
CREATE INDEX idx_registration_end_device ON registration(end_device_id);
CREATE INDEX idx_connection_point_end_device ON connection_point(end_device_id);
CREATE INDEX idx_function_set_assignment_end_device ON function_set_assignment(end_device_id);
CREATE INDEX idx_der_program_ref_function_set_assignment ON der_program_ref(function_set_assignment_id);
CREATE INDEX idx_der_program_ref_der_program ON der_program_ref(der_program_id);
CREATE INDEX idx_default_der_control_der_program ON default_der_control(der_program_id);
CREATE INDEX idx_der_control_der_program ON der_control(der_program_id);
CREATE INDEX idx_der_control_event_status ON der_control(event_status);
CREATE INDEX idx_der_curve_der_program ON der_curve(der_program_id);
CREATE INDEX idx_der_curve_event_status ON der_curve(event_status);
CREATE INDEX idx_response_end_device ON response(end_device_id);
CREATE INDEX idx_subscription_end_device ON subscription(end_device_id);
CREATE INDEX idx_subscription_lifecycle ON subscription(lifecycle);
CREATE INDEX idx_mirror_usage_point_end_device ON mirror_usage_point(end_device_id);
CREATE INDEX idx_log_event_end_device ON log_event(end_device_id);

CREATE OR REPLACE FUNCTION check_end_device_lifecycle_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.lifecycle = NEW.lifecycle THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.lifecycle = 'active' AND NEW.lifecycle = 'soft_deleted') OR
        (OLD.lifecycle = 'soft_deleted' AND NEW.lifecycle = 'hard_deleted') OR
        (OLD.lifecycle = 'soft_deleted' AND NEW.lifecycle = 'active')
    ) THEN
        RAISE EXCEPTION 'invalid end_device transition: % → %', OLD.lifecycle, NEW.lifecycle;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_end_device_lifecycle
    BEFORE UPDATE OF lifecycle ON end_device
    FOR EACH ROW EXECUTE FUNCTION check_end_device_lifecycle_transition();

CREATE OR REPLACE FUNCTION check_der_control_event_status_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.event_status = NEW.event_status THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.event_status = 'scheduled' AND NEW.event_status = 'active') OR
        (OLD.event_status = 'active' AND NEW.event_status = 'completed') OR
        (OLD.event_status = 'scheduled' AND NEW.event_status = 'cancelled') OR
        (OLD.event_status = 'active' AND NEW.event_status = 'cancelled') OR
        (OLD.event_status = 'scheduled' AND NEW.event_status = 'superseded') OR
        (OLD.event_status = 'active' AND NEW.event_status = 'superseded')
    ) THEN
        RAISE EXCEPTION 'invalid der_control transition: % → %', OLD.event_status, NEW.event_status;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_der_control_event_status
    BEFORE UPDATE OF event_status ON der_control
    FOR EACH ROW EXECUTE FUNCTION check_der_control_event_status_transition();

CREATE OR REPLACE FUNCTION check_der_curve_event_status_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.event_status = NEW.event_status THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.event_status = 'scheduled' AND NEW.event_status = 'active') OR
        (OLD.event_status = 'active' AND NEW.event_status = 'completed') OR
        (OLD.event_status = 'scheduled' AND NEW.event_status = 'cancelled') OR
        (OLD.event_status = 'active' AND NEW.event_status = 'superseded')
    ) THEN
        RAISE EXCEPTION 'invalid der_curve transition: % → %', OLD.event_status, NEW.event_status;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_der_curve_event_status
    BEFORE UPDATE OF event_status ON der_curve
    FOR EACH ROW EXECUTE FUNCTION check_der_curve_event_status_transition();

CREATE OR REPLACE FUNCTION check_subscription_lifecycle_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.lifecycle = NEW.lifecycle THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.lifecycle = 'active' AND NEW.lifecycle = 'expired') OR
        (OLD.lifecycle = 'active' AND NEW.lifecycle = 'terminated')
    ) THEN
        RAISE EXCEPTION 'invalid subscription transition: % → %', OLD.lifecycle, NEW.lifecycle;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_subscription_lifecycle
    BEFORE UPDATE OF lifecycle ON subscription
    FOR EACH ROW EXECUTE FUNCTION check_subscription_lifecycle_transition();

COMMIT;
