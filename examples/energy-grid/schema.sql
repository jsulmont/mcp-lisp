BEGIN;

-- Enum types
CREATE TYPE generator_fuel_type AS ENUM ('gas', 'coal', 'nuclear', 'hydro', 'wind', 'solar');
CREATE TYPE generator_state AS ENUM ('offline', 'starting', 'online', 'stopping', 'tripped');
CREATE TYPE storage_unit_state AS ENUM ('idle', 'charging', 'discharging');
CREATE TYPE demand_response_contract_priority_tier AS ENUM ('1', '2', '3');
CREATE TYPE demand_response_contract_activation_state AS ENUM ('standby', 'notified', 'curtailed', 'restored');
CREATE TYPE dispatch_interval_state AS ENUM ('pending', 'cleared', 'emergency', 'blackout');

CREATE TABLE grid_zone (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    name TEXT NOT NULL,
    demand_mw NUMERIC NOT NULL,
    demand_forecast_mw NUMERIC NOT NULL,
    frequency_hz NUMERIC DEFAULT 60.0,
    import_limit_mw NUMERIC NOT NULL,
    export_limit_mw NUMERIC NOT NULL,
    transfer_mw NUMERIC DEFAULT 0
);

CREATE TABLE generator (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    name TEXT NOT NULL,
    fuel_type generator_fuel_type NOT NULL,  -- gas, coal, nuclear, hydro, wind, solar
    state generator_state DEFAULT 'offline',  -- offline, starting, online, stopping, tripped
    output_mw NUMERIC DEFAULT 0,
    min_output NUMERIC NOT NULL,
    max_output NUMERIC NOT NULL,
    ramp_rate NUMERIC NOT NULL,
    min_up_time NUMERIC NOT NULL,
    min_down_time NUMERIC NOT NULL,
    start_cost NUMERIC NOT NULL,
    marginal_cost NUMERIC NOT NULL,
    emissions_rate NUMERIC NOT NULL,
    intervals_in_state NUMERIC DEFAULT 0,
    grid_zone_id TEXT REFERENCES grid_zone(id),
    CONSTRAINT output_matches_state CHECK ((NOT (state <> 'online') OR (output_mw = 0))),
    CONSTRAINT output_within_bounds CHECK ((NOT (state = 'online') OR ((output_mw >= min_output AND output_mw <= max_output)))),
    CONSTRAINT positive_capacity CHECK ((max_output > 0 AND min_output >= 0 AND min_output < max_output)),
    CONSTRAINT ramp_rate_positive CHECK (ramp_rate > 0),
    CONSTRAINT min_times_positive CHECK ((min_up_time > 0 AND min_down_time > 0)),
    CONSTRAINT emissions_non_negative CHECK ((emissions_rate >= 0 AND (CASE WHEN fuel_type IN ('hydro', 'wind', 'solar') THEN (emissions_rate = 0) ELSE (emissions_rate > 0) END))),
    CONSTRAINT nuclear_constraints CHECK ((NOT (fuel_type = 'nuclear') OR ((min_up_time >= 24 AND min_down_time >= 48 AND min_output >= (0.5 * max_output)))))
);

CREATE TABLE storage_unit (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    name TEXT NOT NULL,
    state storage_unit_state DEFAULT 'idle',  -- idle, charging, discharging
    capacity_mwh NUMERIC NOT NULL,
    soc NUMERIC NOT NULL,
    max_charge_rate NUMERIC NOT NULL,
    max_discharge_rate NUMERIC NOT NULL,
    current_rate NUMERIC DEFAULT 0,
    round_trip_efficiency NUMERIC NOT NULL,
    min_soc NUMERIC DEFAULT 0.1,
    max_soc NUMERIC DEFAULT 0.95,
    cycle_count NUMERIC DEFAULT 0,
    grid_zone_id TEXT REFERENCES grid_zone(id),
    CONSTRAINT soc_in_bounds CHECK ((soc >= min_soc AND soc <= max_soc)),
    CONSTRAINT efficiency_valid CHECK ((round_trip_efficiency > 0 AND round_trip_efficiency <= 1.0)),
    CONSTRAINT soc_limits_ordered CHECK ((min_soc >= 0 AND min_soc < max_soc AND max_soc <= 1.0))
    -- inv: rate-matches-state (not translatable to SQL)
    -- inv: rate-within-limits (not translatable to SQL)
    -- inv: soc-after-valid (not translatable to SQL)
);

CREATE TABLE demand_response_contract (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    customer TEXT NOT NULL,
    priority_tier demand_response_contract_priority_tier NOT NULL,  -- 1, 2, 3
    curtailable_mw NUMERIC NOT NULL,
    activation_state demand_response_contract_activation_state DEFAULT 'standby',  -- standby, notified, curtailed, restored
    min_notification_intervals NUMERIC NOT NULL,
    max_curtailment_intervals NUMERIC NOT NULL,
    intervals_in_state NUMERIC DEFAULT 0,
    compensation_rate NUMERIC NOT NULL,
    grid_zone_id TEXT REFERENCES grid_zone(id),
    CONSTRAINT max_curtailment_duration CHECK ((NOT (activation_state = 'curtailed') OR (intervals_in_state <= max_curtailment_intervals))),
    CONSTRAINT compensation_positive CHECK (compensation_rate > 0)
);

CREATE TABLE dispatch_interval (
    id TEXT PRIMARY KEY NOT NULL UNIQUE,
    timestamp TEXT NOT NULL,
    state dispatch_interval_state DEFAULT 'pending',  -- pending, cleared, emergency, blackout
    total_demand_mw NUMERIC NOT NULL,
    total_generation_mw NUMERIC NOT NULL,
    total_storage_mw NUMERIC DEFAULT 0,
    total_curtailment_mw NUMERIC DEFAULT 0,
    system_imbalance_mw NUMERIC DEFAULT 0,
    system_frequency_hz NUMERIC DEFAULT 60.0,
    emissions_tons NUMERIC DEFAULT 0,
    total_cost NUMERIC DEFAULT 0,
    reserve_margin_pct NUMERIC DEFAULT 0,
    CONSTRAINT cleared_means_balanced CHECK ((NOT (state = 'cleared') OR (abs(system_imbalance_mw) <= 50))),
    CONSTRAINT reserve_margin_sane CHECK ((NOT (state = 'cleared') OR (reserve_margin_pct >= 15))),
    CONSTRAINT emergency_threshold CHECK ((NOT (state = 'emergency') OR ((reserve_margin_pct < 15 OR abs(system_imbalance_mw) > 50))))
    -- inv: frequency-reflects-imbalance (not translatable to SQL)
);

CREATE INDEX idx_generator_grid_zone ON generator(grid_zone_id);
CREATE INDEX idx_generator_state ON generator(state);
CREATE INDEX idx_storage_unit_grid_zone ON storage_unit(grid_zone_id);
CREATE INDEX idx_storage_unit_state ON storage_unit(state);
CREATE INDEX idx_demand_response_contract_grid_zone ON demand_response_contract(grid_zone_id);
CREATE INDEX idx_demand_response_contract_activation_state ON demand_response_contract(activation_state);
CREATE INDEX idx_dispatch_interval_state ON dispatch_interval(state);

CREATE OR REPLACE FUNCTION check_generator_state_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.state = NEW.state THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.state = 'offline' AND NEW.state = 'starting') OR
        (OLD.state = 'starting' AND NEW.state = 'online') OR
        (OLD.state = 'online' AND NEW.state = 'stopping') OR
        (OLD.state = 'stopping' AND NEW.state = 'offline') OR
        (OLD.state = 'online' AND NEW.state = 'tripped') OR
        (OLD.state = 'tripped' AND NEW.state = 'offline')
    ) THEN
        RAISE EXCEPTION 'invalid generator transition: % → %', OLD.state, NEW.state;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_generator_state
    BEFORE UPDATE OF state ON generator
    FOR EACH ROW EXECUTE FUNCTION check_generator_state_transition();

CREATE OR REPLACE FUNCTION check_storage_unit_state_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.state = NEW.state THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.state = 'idle' AND NEW.state = 'charging') OR
        (OLD.state = 'idle' AND NEW.state = 'discharging') OR
        (OLD.state = 'charging' AND NEW.state = 'idle') OR
        (OLD.state = 'discharging' AND NEW.state = 'idle')
    ) THEN
        RAISE EXCEPTION 'invalid storage_unit transition: % → %', OLD.state, NEW.state;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_storage_unit_state
    BEFORE UPDATE OF state ON storage_unit
    FOR EACH ROW EXECUTE FUNCTION check_storage_unit_state_transition();

CREATE OR REPLACE FUNCTION check_demand_response_contract_activation_state_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.activation_state = NEW.activation_state THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.activation_state = 'standby' AND NEW.activation_state = 'notified') OR
        (OLD.activation_state = 'notified' AND NEW.activation_state = 'curtailed') OR
        (OLD.activation_state = 'curtailed' AND NEW.activation_state = 'restored') OR
        (OLD.activation_state = 'restored' AND NEW.activation_state = 'standby')
    ) THEN
        RAISE EXCEPTION 'invalid demand_response_contract transition: % → %', OLD.activation_state, NEW.activation_state;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_demand_response_contract_activation_state
    BEFORE UPDATE OF activation_state ON demand_response_contract
    FOR EACH ROW EXECUTE FUNCTION check_demand_response_contract_activation_state_transition();

CREATE OR REPLACE FUNCTION check_dispatch_interval_state_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.state = NEW.state THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.state = 'pending' AND NEW.state = 'cleared') OR
        (OLD.state = 'pending' AND NEW.state = 'emergency') OR
        (OLD.state = 'emergency' AND NEW.state = 'emergency') OR
        (OLD.state = 'emergency' AND NEW.state = 'blackout') OR
        (OLD.state = 'blackout' AND NEW.state = 'pending') OR
        (OLD.state = 'emergency' AND NEW.state = 'cleared')
    ) THEN
        RAISE EXCEPTION 'invalid dispatch_interval transition: % → %', OLD.state, NEW.state;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_dispatch_interval_state
    BEFORE UPDATE OF state ON dispatch_interval
    FOR EACH ROW EXECUTE FUNCTION check_dispatch_interval_state_transition();

COMMIT;
