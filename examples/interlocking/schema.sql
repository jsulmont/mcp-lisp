-- Drop existing objects
DROP TABLE IF EXISTS train CASCADE;
DROP TABLE IF EXISTS route CASCADE;
DROP TABLE IF EXISTS signal CASCADE;
DROP TABLE IF EXISTS point CASCADE;
DROP TABLE IF EXISTS track_section CASCADE;
DROP TABLE IF EXISTS config CASCADE;
DROP TYPE IF EXISTS track_section_state CASCADE;
DROP TYPE IF EXISTS point_position CASCADE;
DROP TYPE IF EXISTS signal_aspect CASCADE;
DROP TYPE IF EXISTS route_state CASCADE;
DROP TYPE IF EXISTS train_state CASCADE;
DROP TYPE IF EXISTS train_heading CASCADE;

-- Enum types
CREATE TYPE track_section_state AS ENUM ('clear', 'occupied');
CREATE TYPE point_position AS ENUM ('normal', 'reverse');
CREATE TYPE signal_aspect AS ENUM ('danger', 'proceed', 'caution', 'preliminary_caution');
CREATE TYPE route_state AS ENUM ('free', 'requesting', 'locked', 'set');
CREATE TYPE train_state AS ENUM ('stopped', 'moving', 'approaching');
CREATE TYPE train_heading AS ENUM ('up', 'down');

-- Config
CREATE TABLE config (
    key   TEXT    PRIMARY KEY,
    value TEXT    NOT NULL
);

INSERT INTO config (key, value) VALUES
    ('approach_lock_timeout', 120),  -- [30, 300]
    ('overlap_hold_time', 120),  -- [60, 300]
    ('point_detection_timeout', 8),  -- [3, 30]
    ('route_release_mode', 'sequential'),
    ('signal_replacement_timeout', 60),  -- [30, 120]
    ('max_approach_speed', 160);  -- [40, 300]

CREATE TABLE track_section (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    state track_section_state DEFAULT 'clear',  -- clear, occupied
    length_m NUMERIC NOT NULL,
    locked_by TEXT DEFAULT '',
    CONSTRAINT section_length_positive CHECK (length_m > 0)
);

CREATE TABLE point (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    position point_position,  -- normal, reverse
    commanded point_position,  -- normal, reverse
    detected BOOLEAN DEFAULT TRUE,
    locked BOOLEAN,
    locked_by TEXT DEFAULT '',
    failed BOOLEAN,
    CONSTRAINT point_lock_position_match CHECK ((NOT (locked) OR ((position = commanded AND detected)))),
    CONSTRAINT point_single_lock CHECK ((CASE WHEN locked_by = '' THEN (NOT (locked)) ELSE (locked) END)),
    CONSTRAINT point_no_move_when_locked CHECK ((NOT (locked) OR (commanded = position)))
);

CREATE TABLE signal (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    aspect signal_aspect DEFAULT 'danger',  -- danger, proceed, caution, preliminary_caution
    replacement_active BOOLEAN,
    approach_locked BOOLEAN
);

CREATE TABLE route (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    entry_signal TEXT NOT NULL,
    exit_signal TEXT DEFAULT '',
    state route_state DEFAULT 'free',  -- free, requesting, locked, set
    sections JSONB NOT NULL,
    point_positions JSONB,
    flank_protections JSONB,
    overlap_sections JSONB,
    overlap_points JSONB,
    conflicts_with JSONB,
    approach_locked BOOLEAN,
    timeout_s NUMERIC DEFAULT 120,
    CONSTRAINT approach_lock_requires_set CHECK ((NOT (approach_locked) OR (state = 'set')))
);

CREATE TABLE train (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    state train_state DEFAULT 'stopped',  -- stopped, moving, approaching
    speed_kmh NUMERIC DEFAULT 0,
    heading train_heading,  -- up, down
    current_sections JSONB,
    authority_route TEXT DEFAULT '',
    berth TEXT DEFAULT '',
    CONSTRAINT train_speed_non_negative CHECK (speed_kmh >= 0),
    CONSTRAINT stopped_means_zero_speed CHECK ((NOT (state = 'stopped') OR (speed_kmh = 0)))
    -- inv: train-speed-within-max (not translatable to SQL)
);

CREATE INDEX idx_signal_aspect ON signal(aspect);
CREATE INDEX idx_route_state ON route(state);
CREATE INDEX idx_train_state ON train(state);

CREATE OR REPLACE FUNCTION check_signal_aspect_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.aspect = NEW.aspect THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.aspect = 'danger' AND NEW.aspect = 'caution')
    ) THEN
        RAISE EXCEPTION 'invalid signal transition: % → %', OLD.aspect, NEW.aspect;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_signal_aspect
    BEFORE UPDATE OF aspect ON signal
    FOR EACH ROW EXECUTE FUNCTION check_signal_aspect_transition();

CREATE OR REPLACE FUNCTION check_route_state_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.state = NEW.state THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.state = 'free' AND NEW.state = 'requesting') OR
        (OLD.state = 'requesting' AND NEW.state = 'locked') OR
        (OLD.state = 'locked' AND NEW.state = 'set') OR
        (OLD.state = 'requesting' AND NEW.state = 'free') OR
        (OLD.state = 'locked' AND NEW.state = 'free') OR
        (OLD.state = 'set' AND NEW.state = 'set') OR
        (OLD.state = 'set' AND NEW.state = 'free') OR
        (OLD.state = 'set' AND NEW.state = 'free')
    ) THEN
        RAISE EXCEPTION 'invalid route transition: % → %', OLD.state, NEW.state;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_route_state
    BEFORE UPDATE OF state ON route
    FOR EACH ROW EXECUTE FUNCTION check_route_state_transition();

CREATE OR REPLACE FUNCTION check_train_state_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.state = NEW.state THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.state = 'stopped' AND NEW.state = 'moving') OR
        (OLD.state = 'approaching' AND NEW.state = 'moving') OR
        (OLD.state = 'moving' AND NEW.state = 'stopped')
    ) THEN
        RAISE EXCEPTION 'invalid train transition: % → %', OLD.state, NEW.state;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_train_state
    BEFORE UPDATE OF state ON train
    FOR EACH ROW EXECUTE FUNCTION check_train_state_transition();

