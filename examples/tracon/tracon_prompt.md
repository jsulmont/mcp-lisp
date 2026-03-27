# Terminal Radar Approach Control (TRACON) — Operational Model (Revised)

A structured model of a terminal radar environment managing arrivals, departures, and overflights into a multi-runway airport. This version emphasizes **geometry, flow structure, and conflict-driven separation**, closer to real TRACON operations.

---

## Core Principles

- Separation is **conflict-based**, not universal pairwise.
- Aircraft follow **routes, vectors, and procedures**, not arbitrary positions.
- Sequencing is **dynamic and advisory**, not strictly ordinal.
- Runway usage is governed by **procedural separation**, not generic timers.
- Handoffs separate **radar control** from **communications transfer**.

---

## What the system tracks

### Aircraft

- `callsign` — unique (e.g. "KLM123")
- `type` — ICAO (e.g. "A320")
- `wake_category` — light / medium / heavy / super
- `position` — lat/lon (degrees)
- `altitude_ft`
- `ground_speed_kt`
- `heading_deg`
- `vertical_rate_fpm`

### Flight intent and state

- `flight_phase` — arrival / departure / overflight / missed / holding
- `route_type` — SID / STAR / vector / direct / visual
- `next_fix` — waypoint or runway intercept
- `assigned_runway` — optional
- `approach_type` — ILS / RNAV / visual / none
- `established_on_final` — boolean

### Control state

- `current_sector`
- `controlling_sector` — radar ownership
- `frequency_sector` — communications ownership
- `handoff_state` — none / initiated / accepted

### Clearances (active instructions)

- `cleared_altitude_ft`
- `cleared_heading_deg` (optional)
- `cleared_speed_kt` (optional)
- `approach_cleared` — boolean

### Other

- `squawk` — 4-digit octal
- `emergency_state` — normal / 7500 / 7600 / 7700

---

### Sectors

Airspace volumes with both lateral and vertical definition.

- `id`
- `name`
- `type` — feeder / final / departure
- `lateral_boundary` — polygon (lat/lon)
- `floor_ft`, `ceiling_ft`
- `capacity`
- `frequency`

---

### Runways

- `id` — e.g. "18R"
- `heading`
- `length_m`
- `config` — arrival / departure / mixed
- `status` — open / closed

### Runway state

- `occupancy_state`:
  - empty
  - landing_roll
  - departing_roll
  - lineup_wait
  - crossing
- `current_aircraft` — optional
- `last_departure` — (wake_category, timestamp)
- `last_arrival` — (wake_category, timestamp)

---

### Routes and Fixes

- `fix` — named waypoint with lat/lon
- `route_segment` — ordered fixes
- `STAR` / `SID` — predefined sequences

---

## Conflict-based separation

Separation is only required for **relevant aircraft pairs**:

### A pair is “relevant” if:

- Same sector **AND**
- One of:
  - distance < 15 NM
  - converging headings (< 45° difference and decreasing distance)
  - same runway flow (arrival or departure)
  - same route segment or merge point

---

### Separation minima

| Context | Minimum |
|--------|--------|
| Standard radar | 3 NM |
| Feeder / enroute-like | 5 NM |
| Vertical | 1000 ft |

Aircraft must satisfy **one of**:
- lateral ≥ minimum
- vertical ≥ minimum

---

## Final approach spacing (wake-driven)

Applies only when:

- both aircraft:
  - assigned same runway
  - established on final

Minimum distance based on wake:

| Leader ↓ \\ Follower → | Super | Heavy | Medium | Light |
|---|---|---|---|---|
| Super | 6 | 7 | 7 | 8 |
| Heavy | 4 | 4 | 5 | 6 |
| Medium | 3 | 3 | 3 | 5 |
| Light | 3 | 3 | 3 | 3 |

---

## Departure separation (procedural)

Two departures from same runway must satisfy:

### One of:

- Radar separation established (≥ 3 NM), OR
- Divergence ≥ 15° **and**:
  - 1 minute spacing (same wake or lighter follower)
  - 2–3 minutes (heavier leader → lighter follower)

---

## Runway usage rules

- Only one aircraft in `landing_roll` or `departing_roll`
- `lineup_wait` allowed only if:
  - no conflicting arrival within threshold (e.g. 2–3 NM final)

### Arrival allowed when:

- runway not occupied by conflicting operation
- preceding arrival sufficiently ahead (runway separation or go-around risk acceptable)

---

## Sequencing model (revised)

Replace strict numbering with:

### Arrival sequence = ordered list per runway

Each aircraft has:
- `sequence_position` — optional (may be undefined)
- `distance_to_threshold_nm`

### Properties:

- Order must match **distance to runway**, not arbitrary numbering
- No requirement for strict contiguity
- Resequencing allowed at any time

---

## Handoffs (revised)

Separate two concepts:

### Radar handoff

- `initiated` → `accepted`
- transfers **control authority**

### Frequency transfer

- independent step
- pilot switches frequency after instruction

### Constraints:

- aircraft must be inside or approaching receiving sector
- receiving sector must have capacity
- aircraft must be separable upon entry

---

## Altitude rules

- Must remain within sector altitude **unless**:
  - climbing/descending with coordination (handoff accepted)

### Semicircular rule

- Applies **only to overflights above FL180**
- May be overridden by ATC assignment

---

## Clearances (simplified realism)

Clearances are not strictly stacked objects. Instead:

Each aircraft maintains current assigned values:

- altitude
- heading (optional)
- speed (optional)
- approach clearance flag

### Rules:

- New instruction replaces prior implicitly
- No need for explicit supersession chains
- Conflicting assignments are invalid

---

## Sector constraints

- Aircraft must be inside sector lateral boundary (with tolerance)
- Sector capacity must not be exceeded
- Aircraft entering sector must be conflict-free

---

## Squawk codes

- 4-digit octal (0–7)
- unique within scenario
- 7500 / 7600 / 7700 reserved for emergency

---

## Go-around / missed approach

When triggered:

- `flight_phase = missed`
- aircraft follows missed approach procedure or vector
- removed from arrival sequence
- must be resequenced

---

## Scenario: realistic busy TRACON snapshot

| Element | Count |
|--------|------|
| Sectors | 3–5 |
| Runways | 2–3 |
| Aircraft | 10–25 |

### Traffic mix

- Arrivals on STARs and vectors
- Departures on SIDs
- Overflights crossing sectors
- 1–3 aircraft in holding

### State conditions

- Some aircraft established on final
- Some being vectored
- Some in active handoff
- Some under speed/altitude control

---

## Invariants (revised)

### Separation

- All **relevant aircraft pairs** must satisfy separation

### Final approach

- Wake spacing must be satisfied for consecutive arrivals

### Runways

- No conflicting occupancy states
- No arrivals on closed runway
- No departures on arrival-only runway

### Sectors

- Capacity not exceeded
- Aircraft within lateral + vertical bounds (with coordination allowance)

### Handoffs

- At most one active radar handoff per aircraft
- Accepted handoffs must not violate separation or capacity

### Clearances

- Assigned values must be internally consistent
- No contradictory instructions

### Sequencing

- Arrival ordering must reflect geometry (distance to runway)

---

## Why this is closer to reality

- Removes artificial “all-pairs” constraint
- Introduces **geometry and flow structure**
- Reflects **controller intent (vectoring, sequencing)**
- Models **procedural separation instead of timers**
- Separates **radar vs radio ownership**
- Allows ambiguity and dynamic resequencing

---

## Still intentionally simplified

This model still omits:

- Weather impacts
- Surveillance uncertainty
- Detailed runway crossing logic
- Complex parallel runway dependency rules
- Human factors / workload modeling

---

## Recommended use

- Simulation engines
- Property-based testing
- Conflict detection systems
- ATC-inspired coordination systems

---

## State Transition Layer

This layer defines the operational events that change aircraft, runway, sector, and control state over time. It turns the model from a static consistency specification into a simulation-ready TRACON state machine.

### Transition design principles

- Every transition has explicit **preconditions** and **effects**.
- Transitions must preserve all invariants.
- If a transition would violate an invariant, it is invalid.
- Some transitions represent **controller actions**; others represent **aircraft progression** or **environmental state changes**.

---

## Transition categories

### Controller-issued transitions

- assign heading
- assign altitude
- assign speed
- clear approach
- cancel approach
- resequence arrival
- initiate radar handoff
- accept radar handoff
- transfer frequency
- assign runway
- issue hold
- cancel hold
- issue go-around

### Aircraft progression transitions

- update kinematics
- cross fix
- intercept course
- establish on final
- enter hold
- exit hold
- land
- depart runway
- execute missed approach
- enter sector
- exit sector

### Runway state transitions

- lineup and wait
- begin takeoff roll
- runway vacated after departure
- touchdown
- runway vacated after landing
- runway crossing begin
- runway crossing complete
- runway close
- runway open

---

## Global transition contract

Each transition may be described as:

```text
TransitionName(parameters)
Preconditions:
  ...
Effects:
  ...
Preserves:
  all model invariants
```

---

## Controller-issued transitions

### AssignHeading(aircraft, heading_deg)

**Preconditions**

- aircraft exists
- aircraft is under control of the issuing sector
- `heading_deg` is in `1..360`
- aircraft is not established on final unless local procedures permit vector breakout

**Effects**

- `cleared_heading_deg = heading_deg`
- any previous heading assignment is implicitly replaced
- aircraft may remain on present heading until kinematic progression updates actual heading

---

### AssignAltitude(aircraft, altitude_ft)

**Preconditions**

- aircraft exists
- aircraft is under control of the issuing sector
- target altitude is operationally valid for current or coordinated next sector
- altitude assignment does not create an immediate unavoidable loss of separation

**Effects**

- `cleared_altitude_ft = altitude_ft`
- prior altitude assignment is implicitly replaced

---

### AssignSpeed(aircraft, speed_kt)

**Preconditions**

- aircraft exists
- aircraft is under control of the issuing sector
- `speed_kt` is within a valid range for aircraft phase and type

**Effects**

- `cleared_speed_kt = speed_kt`
- prior speed assignment is implicitly replaced

---

### AssignRunway(aircraft, runway)

**Preconditions**

- aircraft exists
- aircraft is an arrival or departure
- runway exists and is open
- runway configuration permits intended use

**Effects**

- `assigned_runway = runway`
- aircraft becomes eligible for runway-based sequencing or departure processing

---

### ClearApproach(aircraft, approach_type)

**Preconditions**

- aircraft exists
- aircraft is an arrival
- assigned runway exists and is open
- aircraft is in a valid geometry for the approach, or within permitted intercept criteria
- aircraft is under control of the issuing sector

**Effects**

- `approach_type = approach_type`
- `approach_cleared = true`

---

### CancelApproach(aircraft)

**Preconditions**

- aircraft exists
- `approach_cleared = true`

**Effects**

- `approach_cleared = false`
- aircraft may remain assigned to runway but is no longer approach-cleared

---

### ResequenceArrival(aircraft, new_position)

**Preconditions**

- aircraft exists
- aircraft is an arrival
- aircraft has assigned runway
- resulting order is geometrically achievable or treated as planned sequencing intent

**Effects**

- update runway arrival ordering metadata
- sequence is advisory until aircraft geometry reflects it

---

### IssueHold(aircraft, hold_fix)

**Preconditions**

- aircraft exists
- aircraft is arrival or overflight
- hold fix exists
- holding is operationally allowed in current sector

**Effects**

- `flight_phase = holding`
- `next_fix = hold_fix`

---

### CancelHold(aircraft)

**Preconditions**

- aircraft exists
- `flight_phase = holding`

**Effects**

- aircraft leaves hold and resumes route, vector, or resequencing path

---

### IssueGoAround(aircraft)

**Preconditions**

- aircraft exists
- aircraft is arrival
- aircraft is on final, on approach, or in landing sequence where go-around is operationally meaningful

**Effects**

- `flight_phase = missed`
- `approach_cleared = false`
- aircraft removed from runway arrival sequence
- aircraft follows missed approach route or receives vectors

---

### InitiateRadarHandoff(aircraft, to_sector)

**Preconditions**

- aircraft exists
- aircraft is under current sector control
- `to_sector != current controlling sector`
- no active radar handoff exists

**Effects**

- `handoff_state = initiated`
- proposed receiving sector recorded

---

### AcceptRadarHandoff(aircraft)

**Preconditions**

- aircraft exists
- `handoff_state = initiated`
- receiving sector has capacity
- aircraft can be accepted without invalidating separation assumptions at boundary entry

**Effects**

- `handoff_state = accepted`
- `controlling_sector = receiving sector`

---

### TransferFrequency(aircraft, to_sector)

**Preconditions**

- aircraft exists
- radar handoff has been accepted, or local procedure allows early frequency transfer

**Effects**

- `frequency_sector = to_sector`

---

## Aircraft progression transitions

### UpdateKinematics(aircraft, dt)

Advances aircraft motion over elapsed time `dt`.

**Preconditions**

- aircraft exists
- `dt > 0`

**Effects**

- update position based on current ground speed and heading
- update altitude based on vertical rate
- optionally converge actual heading / speed / altitude toward assigned values according to aircraft dynamics
- may trigger derived events such as fix crossing, localizer interception, runway threshold crossing, or sector boundary crossing

---

### CrossFix(aircraft, fix)

**Preconditions**

- aircraft exists
- aircraft trajectory intersects fix tolerance region

**Effects**

- advance route progression
- update `next_fix`
- may trigger descent, turn, handoff, or approach eligibility

---

### InterceptCourse(aircraft, course)

**Preconditions**

- aircraft exists
- aircraft geometry permits intercept

**Effects**

- aircraft transitions from vector/direct state toward tracked course
- may support STAR segment capture, final approach course capture, or missed-approach routing

---

### EstablishOnFinal(aircraft)

**Preconditions**

- aircraft exists
- aircraft is an arrival
- assigned runway exists
- aircraft is within final approach lateral and angular tolerance
- aircraft is tracking final approach course

**Effects**

- `established_on_final = true`
- aircraft becomes subject to final-approach wake spacing rules

---

### EnterHold(aircraft)

**Preconditions**

- aircraft exists
- hold has been assigned or published hold is active

**Effects**

- `flight_phase = holding`

---

### ExitHold(aircraft)

**Preconditions**

- aircraft exists
- `flight_phase = holding`

**Effects**

- return to arrival, overflight, or vector state

---

### EnterSector(aircraft, sector)

**Preconditions**

- aircraft exists
- aircraft position crosses sector lateral or vertical boundary
- control coordination supports entry
- receiving sector capacity permits entry
- entry state preserves separation

**Effects**

- update `current_sector`

---

### ExitSector(aircraft, sector)

**Preconditions**

- aircraft exists
- aircraft no longer satisfies sector boundary membership

**Effects**

- aircraft leaves sector occupancy set

---

### Land(aircraft, runway)

**Preconditions**

- aircraft exists
- aircraft is an arrival
- assigned runway matches
- aircraft crosses landing threshold in a valid landing state
- runway is not in conflicting occupancy state

**Effects**

- runway `occupancy_state = landing_roll`
- runway `current_aircraft = aircraft`
- aircraft remains associated with runway until vacated

---

### RunwayVacatedAfterLanding(aircraft, runway)

**Preconditions**

- runway current aircraft matches
- runway occupancy state is `landing_roll`
- aircraft exits runway

**Effects**

- runway `occupancy_state = empty`
- runway `current_aircraft = none`
- record `last_arrival`
- aircraft leaves arrival stream and transitions to ground or out-of-model state

---

### LineUpAndWait(aircraft, runway)

**Preconditions**

- aircraft exists
- aircraft is departure
- assigned runway matches
- runway open and not occupied by conflicting roll operation
- no conflicting arrival or crossing state exists within local threshold

**Effects**

- runway `occupancy_state = lineup_wait`
- runway `current_aircraft = aircraft`

---

### BeginTakeoffRoll(aircraft, runway)

**Preconditions**

- aircraft exists
- runway current aircraft matches, or runway available for immediate departure entry
- departure separation from preceding departure is satisfied
- runway is free of conflicting arrival/crossing occupancy

**Effects**

- runway `occupancy_state = departing_roll`
- runway `current_aircraft = aircraft`
- aircraft transitions to departure acceleration state

---

### RunwayVacatedAfterDeparture(aircraft, runway)

**Preconditions**

- runway current aircraft matches
- runway occupancy state is `departing_roll`
- aircraft is airborne and no longer occupying runway

**Effects**

- runway `occupancy_state = empty`
- runway `current_aircraft = none`
- record `last_departure`

---

### ExecuteMissedApproach(aircraft)

**Preconditions**

- aircraft exists
- go-around has been commanded or landing has become unsafe

**Effects**

- `flight_phase = missed`
- `established_on_final = false`
- `approach_cleared = false`
- aircraft follows missed approach profile

---

## Runway state transitions

### Touchdown(aircraft, runway)

A specialized event that may precede `RunwayVacatedAfterLanding`.

**Effects**

- runway enters `landing_roll`

---

### RunwayCrossingBegin(entity, runway)

**Preconditions**

- runway available for crossing
- no conflicting landing or departure roll in progress

**Effects**

- runway `occupancy_state = crossing`

---

### RunwayCrossingComplete(runway)

**Preconditions**

- runway occupancy state is `crossing`

**Effects**

- runway `occupancy_state = empty`
- runway `current_aircraft = none`

---

### CloseRunway(runway)

**Preconditions**

- runway exists
- runway can be safely removed from service

**Effects**

- `status = closed`
- no new arrival/departure clearances may be assigned to it

---

### OpenRunway(runway)

**Preconditions**

- runway exists
- operational availability restored

**Effects**

- `status = open`

---

## Derived events and automatic triggers

Some transitions may be generated automatically from aircraft geometry or elapsed time rather than controller action.

Examples:

- crossing a fix triggers route progression
- crossing localizer capture tolerance triggers `EstablishOnFinal`
- crossing sector boundary triggers `EnterSector`
- reaching runway threshold in landing state triggers `Touchdown`
- unsafe landing geometry or occupied runway may trigger `ExecuteMissedApproach`

---

## Transition ordering within a simulation tick

A practical simulation order for each tick:

1. apply controller actions
2. update aircraft kinematics
3. resolve derived events:
   - fix crossings
   - course interceptions
   - final establishment
   - sector entries/exits
   - runway threshold events
4. apply runway state changes
5. validate invariants
6. reject or roll back invalid transitions if required by engine design

---

## Minimal event schema

A useful event representation:

```text
Event {
  id,
  timestamp,
  type,
  actor,
  target,
  parameters,
  source_sector,
  resulting_state_hash
}
```

This supports replay, auditability, deterministic simulation, and property-based testing.

---

## Notes for implementation

- Keep controller commands separate from physics progression.
- Treat sequencing as intent metadata, not the sole source of truth.
- Use runway occupancy and final-approach spacing as separate checks.
- Validate invariants after each committed transition or tick.
- For property-based generators, build states from route geometry first, then apply control instructions.

