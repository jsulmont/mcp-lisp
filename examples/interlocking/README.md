# Railroad Interlocking

Model a railroad interlocking system — the safety-critical logic that prevents conflicting train movements through junctions. The interlocking controls signals, points (switches), and track circuits, enforcing mutual exclusion of routes that share infrastructure or require conflicting point positions.

This is a classic formal verification domain. The core challenge: safety invariants genuinely conflict with each other, state machines interlock (literally), and random generation of valid states is a constraint satisfaction problem.

## Entities

### track-section

A block of track with occupancy detection (track circuit or axle counter).

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| name | string | e.g. "1T", "2AT", "5BT" |
| state | clear \| occupied | default: clear |
| length-m | number | length in meters, > 0 |
| locked-by | string | route id holding the lock, or "" if unlocked |

### point

A movable junction element (switch/turnout) connecting one track to one of two possible continuations.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| name | string | e.g. "101", "203A" |
| position | normal \| reverse | current detected position |
| commanded | normal \| reverse | position that has been commanded |
| detected | boolean | true if point has reached and been detected in commanded position |
| locked | boolean | default: false |
| locked-by | string | route id holding the lock, or "" |
| failed | boolean | default: false — mechanical or detection failure |

Derived:
- **in-position** = (position = commanded) and detected and not failed

### signal

A fixed lineside signal protecting entry into a route.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| name | string | e.g. "S1", "S24" |
| aspect | danger \| proceed \| caution \| preliminary-caution | default: danger |
| replacement-active | boolean | default: false — signal post replacement button engaged (permits passing signal at danger after timeout) |
| approach-locked | boolean | default: false — train detected in approach section |

Aspect hierarchy (most restrictive to least):
- **danger** (red) — stop
- **caution** (single yellow) — prepare to stop at next signal
- **preliminary-caution** (double yellow) — next signal shows caution
- **proceed** (green) — line clear

### route

A pre-defined path from an entry signal through a sequence of track sections and points to an exit signal. Routes declare all required infrastructure state.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| name | string | e.g. "Route S1→S5 via 101N" |
| entry-signal | string | signal id |
| exit-signal | string | signal id, or "" for terminus/buffer-stop routes |
| state | free \| requesting \| locked \| set | default: free |
| sections | list | ordered track-section ids comprising the route path |
| point-positions | list | each element: {point-id, required-position} |
| flank-protections | list | each element: {point-id, required-position} — points set to prevent unauthorized flank moves into the route |
| overlap-sections | list | track-section ids beyond exit signal required clear as safety margin |
| overlap-points | list | each element: {point-id, required-position} — points in the overlap zone |
| conflicts-with | list | route ids that conflict with this route |
| approach-locked | boolean | default: false |
| timeout-s | number | approach-lock release timeout in seconds |

Derived:
- **all-sections-clear** = every section in `sections` has state = clear and (locked-by = "" or locked-by = this route's id)
- **overlap-clear** = every section in `overlap-sections` has state = clear
- **all-points-set** = every entry in `point-positions` has the point in required position, detected, not failed, and locked by this route
- **flank-protection-set** = every entry in `flank-protections` has the point in required position, detected, and not failed

State machine:
```
free ──[request]──► requesting ──[lock]──► locked ──[set]──► set ──[release]──► free
                        │                                      │
                     [cancel]──► free                    [approach-lock]
                                                         (blocks release)
```

### train

A rail vehicle occupying one or more track sections.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| name | string | e.g. "1A45" (train reporting number) |
| state | stopped \| moving \| approaching | default: stopped |
| speed-kmh | number | default: 0 |
| heading | up \| down | direction of travel |
| current-sections | list | track-section ids currently occupied |
| authority-route | string | route id granting movement authority, or "" |
| berth | string | signal id at which train is berthed (last signal passed or waiting at), or "" |

Derived:
- **has-authority** = authority-route ≠ "" and the referenced route state = set

## Config

| Parameter | Type | Default | Range | Notes |
|---|---|---|---|---|
| approach-lock-timeout | number (s) | 120 | 30–300 | Time before approach lock can be manually released |
| overlap-hold-time | number (s) | 120 | 60–300 | How long overlap must be held after train clears route |
| point-detection-timeout | number (s) | 8 | 3–30 | Max time for a point to reach commanded position |
| route-release-mode | sequential \| full | sequential | — | Sequential releases sections as train passes; full holds all until train exits |
| signal-replacement-timeout | number (s) | 60 | 30–120 | How long replacement button must be held before override |
| max-approach-speed | number (km/h) | 160 | 40–300 | Maximum permitted approach speed |

## Rules

### request-route

- **When:** route is `free`
- **Requires:**
  - All sections in `sections` are clear (not occupied)
  - No route in `conflicts-with` has state `locked` or `set`
  - Entry signal aspect is `danger`
- **Ensures:** state becomes `requesting`, all points in `point-positions` and `flank-protections` are commanded to their required positions

### lock-route

- **When:** route is `requesting`
- **Requires:**
  - All points in `point-positions` are in-position (correct position, detected, not failed)
  - All flank-protection points are in-position
  - All sections still clear
  - No conflicting route has become `locked` or `set` since the request
- **Ensures:** state becomes `locked`, all points in `point-positions` and `overlap-points` become locked with locked-by = this route's id

### set-route

Clear the signal — the critical safety action.

- **When:** route is `locked`
- **Requires:**
  - Overlap sections are clear
  - Overlap points are in correct position and detected
  - All point locks still held
  - All sections still clear
- **Ensures:** state becomes `set`, entry signal aspect changes from `danger` to appropriate aspect:
  - `proceed` if exit signal shows `proceed` or `caution`
  - `caution` if exit signal shows `danger` or route has no exit signal (terminus)
  - `preliminary-caution` only for multi-aspect signaling chains (next signal shows caution)

### cancel-route

- **When:** route is `requesting` or `locked`
- **Requires:**
  - Not approach-locked
  - Entry signal is at `danger`
- **Ensures:** state becomes `free`, all point locks released, signal remains at `danger`

### approach-lock-route

- **When:** route is `set`
- **Requires:**
  - Entry signal aspect ≠ `danger`
  - A train occupies a section immediately before the entry signal (the approach section)
- **Ensures:** approach-locked becomes true

### release-route-sequential

- **When:** route is `set` and config route-release-mode = `sequential`
- **Requires:**
  - A section in the route becomes occupied then clears (train has passed through it)
  - Each cleared section is released: locked-by reset to "", point locks for points only used by that section are released
- **Ensures:** sections released one-by-one as the train passes; when last section clears, route state becomes `free`, entry signal returns to `danger`

### release-route-full

- **When:** route is `set` and config route-release-mode = `full`
- **Requires:**
  - All sections in `sections` were occupied and are now clear (train has fully exited the route)
- **Ensures:** state becomes `free`, all point locks released, entry signal returns to `danger`

### emergency-replacement

Signal post replacement — used when a signal failure or SPAD incident requires overriding a signal at danger.

- **When:** signal aspect is `danger` and replacement-active = true
- **Requires:**
  - Replacement-active has been true for ≥ signal-replacement-timeout seconds
  - The route protected by this signal is in state `set` (all safety conditions still met)
- **Ensures:** signal aspect becomes `caution` (never `proceed` — reduced authority only)

### train-enter

- **When:** train is `stopped` or `approaching` at a signal
- **Requires:**
  - Signal at train's berth shows aspect ≠ `danger`
  - Train has authority (authority-route references a route in state `set`)
  - speed-kmh ≤ max-approach-speed
- **Ensures:** train state becomes `moving`, first section(s) of authority route become `occupied`

### train-stop

- **When:** train is `moving`
- **Ensures:** speed-kmh becomes 0, state becomes `stopped`

## Invariants

### Point safety

1. **point-lock-position-match** — if a point is locked, its position must equal its commanded position and detected must be true
2. **point-single-lock** — a point's locked-by field references at most one route
3. **point-no-move-when-locked** — if a point is locked by a route in state `locked` or `set`, commanded must equal position (nobody can command a locked point to move)
4. **failed-point-blocks-route** — if a point has failed = true, no route requiring that point (in point-positions or overlap-points) may be in state `locked` or `set`

### Signal safety

5. **danger-when-no-route** — if no route with entry-signal = this signal has state `set`, aspect must be `danger`
6. **one-route-per-signal** — at most one route with entry-signal = this signal may be in state `set` at any time
7. **aspect-hierarchy-consistency** — if aspect = `proceed`, the route's exit signal must show `proceed` or `caution`; if aspect = `caution`, the exit signal shows `danger` or exit-signal = "" (terminus)

### Route safety

8. **route-mutual-exclusion** — if route R is `locked` or `set`, no route in R's `conflicts-with` may be `locked` or `set`
9. **conflict-symmetry** — if route A lists route B in conflicts-with, then B must list A
10. **conflict-completeness** — any two routes sharing a track section, or requiring the same point in different positions (including flank-protection vs. point-position conflicts), must appear in each other's conflicts-with
11. **locked-sections-held** — if a route is `locked` or `set`, every section in its `sections` must have locked-by = that route's id
12. **locked-points-held** — if a route is `locked` or `set`, every point in its `point-positions` must have locked = true and locked-by = that route's id
13. **set-requires-overlap-clear** — if a route is `set`, all overlap-sections must have state = clear
14. **approach-lock-blocks-cancel** — if a route is approach-locked, its state must be `set` (cannot be `free`, `requesting`, or `locked`)

### Occupancy safety

15. **no-route-into-occupied** — a track section with state = occupied cannot have its locked-by change to a new route (i.e., no route can newly lock an occupied section — but a route already holding the lock when the train enters is correct)
16. **train-sections-occupied** — every section in a train's current-sections must have state = `occupied`
17. **one-train-per-section** — no track-section id appears in more than one train's current-sections
18. **train-authority-valid** — if a train's authority-route ≠ "", that route must be in state `set`

### Approach locking

19. **approach-lock-requires-set** — if a route is approach-locked, its state must be `set`
20. **approach-lock-signal-cleared** — if a route is approach-locked, its entry signal aspect must be ≠ `danger` (the signal was cleared when the train began its approach)

### Cross-entity referential integrity

21. **section-lock-references-valid** — if a track section's locked-by ≠ "", a route with that id must exist and be in state `locked` or `set`
22. **point-lock-references-valid** — if a point's locked-by ≠ "", a route with that id must exist and be in state `locked` or `set`
23. **route-entry-signal-exists** — every route's entry-signal must reference a valid signal id
24. **route-sections-exist** — every id in a route's sections must reference a valid track-section
25. **route-points-exist** — every point id in a route's point-positions must reference a valid point

### Flank protection

26. **flank-set-when-route-set** — if a route is `set`, every flank-protection point must be in its required position and detected = true
27. **flank-creates-conflict** — if route A requires a point in one position (route or flank) and route B requires the same point in the opposite position (route or flank), they must be in each other's conflicts-with

## Scenario

### junction-interlocking

A realistic junction with converging and diverging tracks — the kind of layout where interlocking earns its name.

| Entity | Count | Notes |
|---|---|---|
| track-sections | 8–15 | forming a junction topology |
| points | 3–6 | at diverging/converging locations |
| signals | 4–10 | protecting each route entry point |
| routes | 6–12 | all valid paths through the junction |
| trains | 1–4 | some stopped, some with movement authority |

Scenario-level invariants:

- **conflict-table-complete** — the conflicts-with lists are the ground truth: every pair of routes sharing a section or requiring conflicting point positions appears in each other's list (no missing conflicts)
- **no-double-lock** — no section or point is locked-by more than one route simultaneously
- **global-point-consistency** — across all routes in state `locked` or `set`, no two routes require the same point in different positions
- **authority-covers-train** — every moving train's current-sections must be a subset of its authority-route's sections

## PBT strategy

This spec is deliberately among the hardest to generate valid instances for. The difficulty isn't in any single invariant — it's that they interact.

**Route conflict consistency:** The conflicts-with lists must be symmetric (invariant 9) and complete (invariant 10). Random generation of conflict lists will almost always violate one or both. The generator must *compute* conflicts from shared sections and point positions, never generate them independently.

**Global point position consistency:** If route A (set) needs point 1 in normal and route B (set) needs point 1 in reverse, that's a violation of route-mutual-exclusion. But this only works if the conflict table correctly identifies A and B as conflicting — so the generator must get the conflict table right *first*, then choose non-conflicting routes to set.

**Bidirectional locking:** When a route is locked/set, every section and point must have locked-by = that route. But locked-by is a field on the section/point, not on the route — the generator must write both sides consistently. A section can only be locked by one route (point-single-lock, no-double-lock), so the generator must verify no infrastructure is claimed by multiple active routes.

**Approach locking circularity:** A route can't be cancelled when approach-locked (invariant 14), approach locking requires the route to be `set` (invariant 19) with signal cleared (invariant 20), and a train in the approach section. The generator must construct these coupled states together — not independently.

**Flank protection cascading conflicts:** Flank protections create hidden conflicts. Route A might not share any sections with route B, but if A requires point 3 normal for flank protection and B requires point 3 reverse for its path, they conflict (invariant 27). The conflict table computation must include flank protections, not just route point-positions.

### Suggested generator approach

```
1. Build a track layout:
   a. Create 8–15 track sections with names and lengths
   b. Place 3–6 points at junction locations
   c. Place signals at route entry points

2. Define routes from the topology:
   a. For each valid path (signal → sections → signal), record required point positions
   b. Determine flank protections for each route
   c. Determine overlap sections and overlap points
   d. Compute the conflict table: for every pair of routes, check
      - shared sections
      - same point required in different positions (including flank vs. route)
   e. conflicts-with is symmetric by construction

3. Choose a consistent active state:
   a. Pick 0–3 non-conflicting routes (using the conflict table) to be `set`
   b. For each set route: set locked-by on all its sections and points
   c. Set entry signal aspects consistent with exit signal aspects
   d. All other routes stay `free`

4. Place trains:
   a. For each set route, optionally place a train
   b. Train's current-sections ⊆ route's sections
   c. Mark those sections as occupied
   d. If train is in approach area, set approach-locked on route

5. Verify: every section locked-by at most one route,
   every point locked-by at most one route,
   no two set routes require conflicting point positions
```

The hardest part is step 2d — computing a correct and complete conflict table that includes flank protection interactions — and step 3a — choosing maximally non-conflicting route subsets while maintaining global point consistency. Random generation without this structured approach will fail on nearly every trial.
