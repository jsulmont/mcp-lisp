# Aircraft Weight & Balance / Flight Planning System

A single-page web application for computing aircraft weight and balance, building flight plans from real waypoints, and validating dispatch safety constraints including fuel ladder checks at every waypoint.

## Data

### `waypoints.json`

A static dataset of 59 real waypoints and 16 FAA preferred IFR routes. Coordinates sourced from the FAA NASR 28-day subscription database.

Each waypoint:
```json
{"id": "MERIT", "identifier": "MERIT", "name": "MERIT", "lat": 41.38195, "lon": -73.137431, "elevation": 0, "type": "fix"}
```

Fields: `id` (string, unique), `identifier` (string), `name` (string), `lat` (decimal degrees), `lon` (decimal degrees), `elevation` (ft MSL), `type` ("airport" | "navaid" | "fix").

**Waypoint counts:** 10 airports, 9 navaids (VORs), 40 named fixes/intersections.

**Airports:** KATL, KBOS, KDCA, KIAD, KJFK, KLAX, KMIA, KORD, KSEA, KSFO.

**Navaids:** ATR (Waterloo), CAM (Cambridge), DKK (Dunkirk), FNT (Flint), JHW (Jamestown), RBV (Robbinsville), SEY (Sandy Point), SVM (Salem), VTU (Ventura).

**Fixes:** AGARD, BROSS, BUZRD, CAMRN, COATE, DONIL, DOXXY, DUFEE, EBAKE, ERAVE, ETCHY, FLASK, HAAKK, HONID, HYLND, KAYYS, KELLN, KIWII, KNUKK, LAFLN, LAIRI, LARZZ, LOGGR, LUCKK, MERIT, MLBEC, PADDE, PANZE, PONCT, POSTS, SADDE, SHRKS, SOSIC, SSOXS, STYMY, SWANN, WAVES, WISMO, WLKES, ZIZZI.

Each route:
```json
{"id": "R01", "from": "KJFK", "to": "KBOS", "waypoints": ["KJFK", "MERIT", "KBOS"]}
```

**16 routes** covering short hops (KJFK-KBOS, 2 fixes), medium corridors (KBOS-KDCA, 5 fixes), and long cross-country (KORD-KJFK, 7 fixes):

| ID | Route | Waypoints |
|----|-------|-----------|
| R01 | KJFK → KBOS | KJFK MERIT KBOS |
| R02 | KBOS → KJFK | KBOS SSOXS BUZRD SEY KJFK |
| R03 | KJFK → KORD | KJFK COATE KAYYS KORD |
| R04 | KORD → KJFK | KORD DUFEE LOGGR HAAKK DOXXY SOSIC JHW WLKES KJFK |
| R05 | KJFK → KIAD | KJFK RBV KIAD |
| R06 | KIAD → KJFK | KIAD AGARD DONIL PANZE CAMRN KJFK |
| R07 | KBOS → KDCA | KBOS SSOXS ZIZZI KNUKK ATR LAFLN KDCA |
| R08 | KDCA → KBOS | KDCA SWANN BROSS KJFK KBOS |
| R09 | KBOS → KORD | KBOS HYLND CAM FNT KORD |
| R10 | KORD → KBOS | KORD EBAKE WISMO POSTS PADDE SVM DKK PONCT KBOS |
| R11 | KDCA → KATL | KDCA FLASK KATL |
| R12 | KATL → KDCA | KATL KELLN KIWII WAVES KDCA |
| R13 | KATL → KMIA | KATL LUCKK HONID KMIA |
| R14 | KMIA → KATL | KMIA STYMY SHRKS LAIRI LARZZ KATL |
| R15 | KSEA → KSFO | KSEA ERAVE ETCHY MLBEC KSFO |
| R16 | KSFO → KLAX | KSFO VTU SADDE KLAX |

### Aircraft performance profiles

Three hardcoded types. All fuel in lbs, speeds in knots TAS, altitudes in feet.

| | C172S (single-engine) | BE58 Baron (twin-engine) | PC-12 (turboprop) |
|---|---|---|---|
| Basic empty weight | 1,680 lbs | 3,940 lbs | 6,260 lbs |
| Basic empty moment | 63,840 lb·in | 291,560 lb·in | 964,040 lb·in |
| Max takeoff weight | 2,550 lbs | 5,400 lbs | 10,450 lbs |
| Max landing weight | 2,550 lbs | 5,400 lbs | 10,045 lbs |
| Max zero-fuel weight | 2,200 lbs | 4,800 lbs | 8,748 lbs |
| Max fuel capacity | 318 lbs | 600 lbs | 2,704 lbs |
| Fuel arm | 48.0 in | 74.0 in | 154.0 in |
| Climb burn rate | 61 lbs/hr | 216 lbs/hr | 476 lbs/hr |
| Cruise burn rate | 50 lbs/hr | 144 lbs/hr | 272 lbs/hr |
| Descent burn rate | 27 lbs/hr | 60 lbs/hr | 122 lbs/hr |
| Cruise TAS | 122 kts | 195 kts | 260 kts |
| Climb TAS | 75 kts | 120 kts | 160 kts |
| Descent TAS | 105 kts | 150 kts | 200 kts |
| Rate of climb | 730 fpm | 1,700 fpm | 1,920 fpm |
| Rate of descent | 500 fpm | 800 fpm | 1,200 fpm |
| Service ceiling | 14,000 ft | 20,700 ft | 30,000 ft |
| Forward CG limit | 35.0 in | 73.0 in | 144.0 in |
| Aft CG limit | 47.3 in | 83.0 in | 158.0 in |
| Vs0 (stall, landing) | 40 kts | 69 kts | 67 kts |
| Vs1 (stall, clean) | 48 kts | 78 kts | 80 kts |
| Vx (best angle) | 62 kts | 84 kts | 110 kts |
| Vy (best rate) | 74 kts | 96 kts | 120 kts |
| Va (maneuvering) | 99 kts | 140 kts | 155 kts |
| Vne (never exceed) | 163 kts | 223 kts | 240 kts |
| Vfe (max flap ext) | 85 kts | 130 kts | 170 kts |

## Entities

### aircraft

The airframe and its fixed characteristics.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| registration | string | e.g., N12345 |
| type | single-engine \| twin-engine \| turboprop | selects a performance profile |
| basic-empty-weight | number (lbs) | |
| basic-empty-moment | number (lb·in) | |
| max-takeoff-weight | number (lbs) | |
| max-landing-weight | number (lbs) | |
| max-zero-fuel-weight | number (lbs) | |
| forward-cg-limit | number (in aft of datum) | |
| aft-cg-limit | number (in aft of datum) | |

Relations: has many **load-items**, has one **fuel-load**, has one **performance-profile**.

PBT generator: pick one of the three hardcoded profiles at random and populate all fields from it.

### performance-profile

Engine and aerodynamic performance data. One per aircraft type; values come from the hardcoded table above.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| climb-burn-rate | number (lbs/hr) | |
| cruise-burn-rate | number (lbs/hr) | |
| descent-burn-rate | number (lbs/hr) | |
| climb-tas | number (kts) | |
| cruise-tas | number (kts) | |
| descent-tas | number (kts) | |
| rate-of-climb | number (fpm) | |
| rate-of-descent | number (fpm) | |
| service-ceiling | number (ft) | |
| vs0 | number (kts) | stall speed, landing config |
| vs1 | number (kts) | stall speed, clean |
| vx | number (kts) | best angle of climb |
| vy | number (kts) | best rate of climb |
| va | number (kts) | maneuvering speed |
| vne | number (kts) | never exceed speed |
| vfe | number (kts) | max flap extended speed |

Relation: belongs to **aircraft**.

PBT generator: always pick one of the three hardcoded profiles (C172S, BE58, PC-12) — never generate random values.

### load-item

A discrete weight placed in the aircraft.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| description | string | e.g., "Pilot", "Rear passenger" |
| weight | number (lbs) | must be > 0 |
| arm | number (in aft of datum) | station location |
| category | pilot \| passenger \| baggage \| cargo | |
| zone | forward \| aft \| left \| right | |

Derived: **moment** = weight × arm.

Relation: belongs to **aircraft**.

PBT generator: weight in [100, 250] for persons, [5, 120] for baggage/cargo. Arm within the aircraft's [forward-cg-limit, aft-cg-limit] range.

### fuel-load

Fuel on board at departure. No burn rate — burn is computed from the flight plan and performance profile.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| fuel-weight | number (lbs) | fuel at departure |
| fuel-arm | number (in aft of datum) | fuel tank CG station |
| max-fuel-capacity | number (lbs) | |

Derived: **fuel-moment** = fuel-weight × fuel-arm.

Relation: belongs to **aircraft**.

PBT generator: fuel-arm and max-fuel-capacity from the selected aircraft profile. fuel-weight in [0, max-fuel-capacity].

### waypoint

A navigation fix. Read-only, loaded from `waypoints.json`.

| Field | Type | Notes |
|---|---|---|
| id | string | unique, same as identifier |
| identifier | string | ICAO code |
| name | string | human-readable name |
| lat | number | decimal degrees |
| lon | number | decimal degrees |
| elevation | number (ft MSL) | |
| type | airport \| navaid \| fix | |

Not generated by PBT — used as a lookup table by other generators.

### flight-plan

An ordered sequence of legs from departure to destination.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| name | string | e.g., "KJFK → KBOS" |

Relations: belongs to **dispatch**, has many **flight-legs** (ordered by sequence).

PBT generator: pick one of the 16 routes from `waypoints.json` at random. Generate flight-legs from the route's waypoint list.

### flight-leg

One segment between two consecutive waypoints.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| sequence | number | 1-based ordering |
| from-waypoint | string | waypoint identifier, must exist in `waypoints.json` |
| to-waypoint | string | waypoint identifier, must exist in `waypoints.json` |
| planned-altitude | number (ft MSL) | cruise altitude for this leg |

Derived fields (computed from waypoint coordinates, altitude, and the aircraft's performance profile):

- **distance** — great-circle distance in nautical miles (haversine on waypoint lat/lon)
- **phase** — `climb` if planned-altitude > previous altitude (departure elevation for first leg), `descent` if planned-altitude < next altitude (destination elevation for last leg), otherwise `cruise`
- **altitude-delta** — absolute altitude change in feet (0 for cruise)
- **climb-distance** — horizontal distance during altitude change = altitude-delta / (rate-of-climb or rate-of-descent) × (climb or descent TAS) / 60
- **cruise-distance** — distance − climb-distance
- **climb-time** — climb-distance / phase-TAS (hours)
- **cruise-time** — cruise-distance / cruise-TAS (hours)
- **estimated-time** — climb-time + cruise-time (hours)
- **fuel-burn** — (climb-time × climb/descent-burn-rate) + (cruise-time × cruise-burn-rate) (lbs)

Relation: belongs to **flight-plan**.

PBT generator: from-waypoint and to-waypoint come from the selected route. planned-altitude between max(departure-elevation, destination-elevation) + 1000 and service-ceiling.

### fuel-ladder-entry

Fuel state at a waypoint. Computed during dispatch, not stored.

| Field | Type | Notes |
|---|---|---|
| waypoint | string | waypoint identifier |
| sequence | number | matches leg sequence |
| fuel-remaining | number (lbs) | fuel after this leg's burn |
| weight-at-waypoint | number (lbs) | total weight at this point |
| cg-at-waypoint | number (in) | CG position at this point |
| cumulative-burn | number (lbs) | total fuel burned so far |
| cumulative-time | number (hrs) | total time elapsed |

### cg-envelope

One vertex of the CG envelope polygon. Defines allowable CG range as a function of weight.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| reference-weight | number (lbs) | |
| forward-limit | number (in) | |
| aft-limit | number (in) | |

Relation: belongs to **aircraft**.

### dispatch

The top-level computation. Ties together aircraft, loading, fuel, and flight plan.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| state | draft \| computed \| approved \| rejected | default: draft |
| pilot-in-command | string | |
| total-weight | number (lbs) | takeoff weight |
| total-moment | number (lb·in) | |
| cg-position | number (in) | takeoff CG |
| landing-weight | number (lbs) | weight at destination |
| landing-moment | number (lb·in) | |
| landing-cg | number (in) | CG at destination |
| total-fuel-burn | number (lbs) | sum of all leg burns |
| total-flight-time | number (hrs) | sum of all leg times |
| min-fuel-remaining | number (lbs) | lowest fuel point in the ladder |
| reserve-fuel-required | number (lbs) | 30 min cruise burn (VFR) or 45 min (IFR) |

Relations: belongs to **aircraft**, has one **flight-plan**.

PBT generator for state=approved or state=computed: assemble a valid aircraft (from profile), load items (at least one pilot), fuel (within capacity), flight plan (from a real route), then run the compute-dispatch computation to derive all fields. This ensures structural consistency.

## Rules

### compute-dispatch

Computes all weight, balance, and fuel fields from inputs.

- **When:** dispatch is in `draft` state
- **Requires:**
  - Aircraft has at least one load-item with category `pilot`
  - fuel-load fuel-weight > 0
  - Flight plan has at least one leg
- **Ensures:**
  - State becomes `computed`
  - total-weight = basic-empty-weight + Σ(load-item weights) + fuel-weight
  - total-moment = basic-empty-moment + Σ(load-item moments) + fuel-moment
  - cg-position = total-moment / total-weight
  - total-fuel-burn = Σ(leg fuel-burns)
  - landing-weight = total-weight − total-fuel-burn
  - landing-moment = total-moment − (total-fuel-burn × fuel-arm)
  - landing-cg = landing-moment / landing-weight
  - Fuel ladder computed for every waypoint
  - min-fuel-remaining = min of all fuel-ladder fuel-remaining values
  - reserve-fuel-required = 45 min × cruise-burn-rate (IFR)

### approve-dispatch

- **When:** dispatch is in `computed` state
- **Requires:**
  - total-weight ≤ max-takeoff-weight
  - landing-weight ≤ max-landing-weight
  - (total-weight − fuel-weight) ≤ max-zero-fuel-weight
  - cg-position ∈ [forward-cg-limit, aft-cg-limit]
  - landing-cg ∈ [forward-cg-limit, aft-cg-limit]
  - min-fuel-remaining ≥ reserve-fuel-required
  - No leg's planned-altitude exceeds service-ceiling
- **Ensures:** state becomes `approved`

### reject-dispatch

- **When:** dispatch is in `computed` state
- **Requires:** any approval condition is violated
- **Ensures:** state becomes `rejected`

### recompute-dispatch

- **When:** dispatch is in `computed` or `rejected` state
- **Ensures:** state returns to `draft`

## Invariants

### Structural (always hold)

1. **moment-is-weight-times-arm** (load-item) — moment = weight × arm
2. **fuel-moment-correct** (fuel-load) — fuel-moment = fuel-weight × fuel-arm
3. **positive-weights** (load-item) — weight > 0
4. **fuel-within-capacity** (fuel-load) — 0 ≤ fuel-weight ≤ max-fuel-capacity

### Aircraft limits

5. **cg-limits-ordered** (aircraft) — forward-cg-limit < aft-cg-limit
6. **weight-limits-ordered** (aircraft) — max-landing-weight ≤ max-takeoff-weight
7. **zero-fuel-weight-bounded** (aircraft) — max-zero-fuel-weight ≤ max-takeoff-weight

### Performance sanity

8. **speeds-ordered** (performance-profile) — vs0 < vs1 < vx < vy < va < vne
9. **climb-faster-than-stall** (performance-profile) — climb-tas > vs1
10. **cruise-faster-than-climb** (performance-profile) — cruise-tas > climb-tas
11. **positive-burn-rates** (performance-profile) — all three burn rates > 0
12. **positive-rates** (performance-profile) — rate-of-climb > 0 and rate-of-descent > 0

### Flight plan

13. **positive-leg-distance** (flight-leg) — distance > 0 (from ≠ to waypoint)
14. **altitude-below-ceiling** (flight-leg) — planned-altitude ≤ service-ceiling
15. **positive-fuel-burn** (flight-leg) — fuel-burn > 0

### Dispatch

16. **approved-within-limits** (dispatch) — if approved: total-weight > 0, landing-weight > 0, landing-weight ≤ total-weight
17. **dispatch-cg-sane** (dispatch) — if approved or computed: cg-position > 0
18. **fuel-reserves-met** (dispatch) — if approved: min-fuel-remaining ≥ reserve-fuel-required
19. **landing-fuel-non-negative** (dispatch) — if computed or approved: landing-weight < total-weight

## PBT strategy

Generators must produce structurally valid instances by construction, not by random fields:

- **aircraft** and **performance-profile**: always select one of the three hardcoded profiles (C172S, BE58, PC-12). This guarantees invariants 5-12 by construction.
- **load-item**: positive weight, arm within aircraft CG range. Compute derived moment. Guarantees invariants 1, 3.
- **fuel-load**: fuel-weight in [0, max-fuel-capacity], arm and capacity from profile. Compute derived fuel-moment. Guarantees invariants 2, 4.
- **flight-leg**: pick from-waypoint and to-waypoint from a real route in `waypoints.json`. Look up coordinates, compute haversine distance. Set planned-altitude ≤ service-ceiling. Compute all derived fields. Guarantees invariants 13-15.
- **dispatch** (computed/approved states): assemble a full valid scenario — aircraft from profile, at least one pilot load-item, fuel, a real route from `waypoints.json` — then run compute-dispatch logic to derive all fields. Guarantees invariants 16-19.

The key insight: entities with derived fields and cross-entity constraints cannot be generated field-by-field. Generators must build valid composite scenarios and compute derivations, using real route data from `waypoints.json` as inputs.

## UI Layout

Single page, no routing. Four panels:

### 1. Aircraft & Loading (left)

- Dropdown: select aircraft type (pre-fills all fields from profile)
- Registration text input
- Load items table (add/remove rows): description, weight, arm, category, zone
- Fuel weight slider (clamped to [0, max-fuel-capacity])
- Running totals: zero-fuel weight, ramp weight

### 2. Flight Plan (center-left)

- Route picker: dropdown of the 16 predefined routes, or build custom by selecting waypoints
- Waypoint search: type-ahead on identifier or name from `waypoints.json`
- Ordered waypoint list with per-leg altitude input
- Computed per leg: distance, time, fuel burn, phase
- Totals: distance, time, fuel burn

### 3. Results & Fuel Ladder (center-right)

- Dispatch status badge (draft / computed / approved / rejected)
- Summary: takeoff weight, landing weight, takeoff CG, landing CG, total fuel burn, flight time
- Fuel ladder table: waypoint, fuel remaining, weight, CG, cumulative burn, cumulative time
- Constraint violations highlighted as warnings/errors

### 4. CG Envelope Chart (right)

- X axis: CG position (in aft of datum)
- Y axis: weight (lbs)
- CG envelope polygon
- Takeoff point (weight, CG) and landing point (weight, CG)
- Green if inside envelope, red if outside
- Optional: fuel ladder intermediate points

## Tech Stack

- Single `index.html` with inline CSS and JS, no build step
- `waypoints.json` loaded via fetch or inlined
- Canvas or SVG for CG envelope chart
- All computation client-side
- Aircraft performance profiles as a JS object literal
