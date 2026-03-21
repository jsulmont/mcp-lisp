# Smart Energy Grid Dispatch

Model an energy grid dispatch system with generators, battery storage, demand-response contracts, and 5-minute dispatch intervals. The grid must continuously balance supply and demand while respecting generator physics, storage limits, and cascading curtailment priorities.

## Entities

### generator

A power generation unit with a multi-state lifecycle.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| name | string | e.g., "Oakdale Gas Turbine #2" |
| fuel-type | gas \| coal \| nuclear \| hydro \| wind \| solar | |
| state | offline \| starting \| online \| stopping \| tripped | default: offline |
| output-mw | number | current output in megawatts, 0 when not online |
| min-output | number (MW) | minimum stable generation when online |
| max-output | number (MW) | nameplate capacity |
| ramp-rate | number (MW/min) | max output change per minute |
| min-up-time | number (intervals) | once online, must stay online this many 5-min intervals |
| min-down-time | number (intervals) | once offline, must stay offline this many intervals |
| start-cost | number ($) | cost to start the unit |
| marginal-cost | number ($/MWh) | fuel + variable O&M per MWh |
| emissions-rate | number (tons CO2/MWh) | 0 for renewables |
| intervals-in-state | number | how many intervals the unit has been in its current state |

Derived:
- **output-cost** = output-mw × marginal-cost / 12 (cost per 5-min interval)
- **output-emissions** = output-mw × emissions-rate / 12 (emissions per interval)
- **can-increase** = min(max-output − output-mw, ramp-rate × 5) when online, else 0
- **can-decrease** = min(output-mw − min-output, ramp-rate × 5) when online, else 0

Relations: belongs to **grid-zone**.

State machine:
```
offline ──[start]──► starting ──[sync]──► online ──[stop]──► stopping ──► offline
                                            │
                                       [trip]──► tripped ──[clear]──► offline
```
- `offline → starting`: requires intervals-in-state ≥ min-down-time
- `starting → online`: requires intervals-in-state ≥ 2 (10 min start-up; nuclear = 24 intervals / 2 hrs)
- `online → stopping`: requires intervals-in-state ≥ min-up-time
- `stopping → offline`: requires intervals-in-state ≥ 1
- `online → tripped`: unconditional (fault)
- `tripped → offline`: requires intervals-in-state ≥ 6 (30 min lockout)

### storage-unit

A battery energy storage system (BESS).

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| name | string | |
| state | idle \| charging \| discharging | default: idle |
| capacity-mwh | number | total energy capacity |
| soc | number | state of charge, 0.0–1.0 |
| max-charge-rate | number (MW) | max power input |
| max-discharge-rate | number (MW) | max power output |
| current-rate | number (MW) | positive = discharging, negative = charging, 0 = idle |
| round-trip-efficiency | number | 0.0–1.0, typically 0.85–0.92 |
| min-soc | number | minimum allowed SOC, typically 0.1 |
| max-soc | number | maximum allowed SOC, typically 0.95 |
| cycle-count | number | cumulative full-equivalent cycles |

Derived:
- **available-energy** = (soc − min-soc) × capacity-mwh (MWh available to discharge)
- **available-capacity** = (max-soc − soc) × capacity-mwh (MWh available to absorb)
- **soc-after-interval** = soc + (current-rate × efficiency-factor / capacity-mwh / 12), where efficiency-factor = round-trip-efficiency when charging, 1.0 when discharging

State constraints:
- `idle → charging`: only if soc < max-soc
- `idle → discharging`: only if soc > min-soc
- `charging → discharging` and `discharging → charging`: **prohibited** — must pass through idle (prevents hunting)
- `charging` or `discharging → idle`: unconditional

Relations: belongs to **grid-zone**.

### demand-response-contract

An agreement with a consumer to curtail load on demand.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| customer | string | |
| priority-tier | 1 \| 2 \| 3 | 1 = first to curtail (industrial), 3 = last (residential) |
| curtailable-mw | number | load that can be shed |
| activation-state | standby \| notified \| curtailed \| restored | default: standby |
| min-notification-intervals | number | minimum notice before curtailment (tier 1 = 1, tier 3 = 6) |
| max-curtailment-intervals | number | maximum consecutive intervals curtailed |
| intervals-in-state | number | how long in current activation-state |
| compensation-rate | number ($/MWh) | payment for curtailed energy |

State machine:
```
standby ──[notify]──► notified ──[activate]──► curtailed ──[release]──► restored ──► standby
```
- `standby → notified`: unconditional
- `notified → curtailed`: requires intervals-in-state ≥ min-notification-intervals
- `curtailed → restored`: unconditional (but max-curtailment-intervals enforced by invariant)
- `restored → standby`: requires intervals-in-state ≥ 2 (10 min recovery)

Relations: belongs to **grid-zone**.

### grid-zone

A section of the grid with its own supply/demand balance.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| name | string | e.g., "North Region" |
| demand-mw | number | current total demand |
| demand-forecast-mw | number | predicted demand for next interval |
| frequency-hz | number | nominal 60.000 Hz |
| import-limit-mw | number | max power importable from other zones |
| export-limit-mw | number | max power exportable to other zones |
| transfer-mw | number | current inter-zone transfer (positive = importing) |

Derived:
- **total-generation** = Σ(generator.output-mw) for all generators in zone
- **total-storage-output** = Σ(storage-unit.current-rate) for all storage units in zone (positive = net discharge)
- **total-curtailment** = Σ(contract.curtailable-mw) for all curtailed contracts in zone
- **supply** = total-generation + total-storage-output + total-curtailment + transfer-mw
- **imbalance** = supply − demand-mw
- **reserve-margin** = (Σ can-increase for online generators + Σ available discharge for storage) / demand-mw

Relations: has many **generators**, has many **storage-units**, has many **demand-response-contracts**.

### dispatch-interval

A 5-minute market clearing snapshot. The top-level entity tying everything together.

| Field | Type | Notes |
|---|---|---|
| id | string | unique |
| timestamp | string | ISO 8601 |
| state | pending \| cleared \| emergency \| blackout | default: pending |
| total-demand-mw | number | sum across all zones |
| total-generation-mw | number | sum across all zones |
| total-storage-mw | number | net storage (positive = discharge) |
| total-curtailment-mw | number | total demand curtailed |
| system-imbalance-mw | number | total supply − total demand |
| system-frequency-hz | number | derived from imbalance |
| emissions-tons | number | total CO2 this interval |
| total-cost | number ($) | total dispatch cost this interval |
| reserve-margin-pct | number | system-wide reserve margin |

State machine:
```
pending ──[clear]──► cleared
pending ──[emergency]──► emergency ──[resolve]──► cleared
pending ──[blackout]──► blackout ──[restore]──► pending
```

## Rules

### clear-dispatch

The normal market clearing process.

- **When:** dispatch-interval is `pending`
- **Requires:**
  - system-imbalance-mw is within [-50, +50] MW (tolerance band)
  - system-frequency-hz is within [59.95, 60.05] Hz
  - No generator has output-mw > max-output or (online with output-mw < min-output)
  - All online generators' output changes from previous interval respect ramp-rate × 5
  - No storage unit's soc-after-interval violates [min-soc, max-soc]
  - Reserve-margin-pct ≥ 15%
  - All curtailed demand-response-contracts have priority ordering respected (no tier-N curtailed while a tier-(N-1) contract in same zone is on standby)
- **Ensures:** state becomes `cleared`

### declare-emergency

Grid stress event.

- **When:** dispatch-interval is `pending`
- **Requires:**
  - reserve-margin-pct < 7% OR
  - |system-imbalance-mw| > 100 OR
  - any generator just tripped (state = tripped, intervals-in-state = 0)
- **Ensures:**
  - state becomes `emergency`
  - All tier-1 demand-response-contracts are notified or curtailed

### escalate-curtailment

Progressive load shedding during emergency.

- **When:** dispatch-interval is `emergency`
- **Requires:**
  - system-imbalance-mw < -50 (demand exceeds supply by > 50 MW)
  - At least one demand-response-contract in a lower priority tier is still on standby
  - All contracts of every higher-priority tier are already curtailed
- **Ensures:**
  - The next priority tier's contracts move to notified

### declare-blackout

Unrecoverable loss of supply.

- **When:** dispatch-interval is `emergency`
- **Requires:**
  - system-imbalance-mw < -200 (severe supply deficit)
  - All demand-response-contracts are curtailed (all tiers exhausted)
  - No generator can increase output (Σ can-increase = 0)
  - All storage units are at min-soc or idle
- **Ensures:** state becomes `blackout`

### start-generator

- **When:** generator is `offline`
- **Requires:**
  - intervals-in-state ≥ min-down-time
  - (For nuclear: grid frequency > 59.90 Hz — no nuclear start during severe frequency deviation)
- **Ensures:** state becomes `starting`, output-mw stays 0, intervals-in-state resets to 0

### sync-generator

- **When:** generator is `starting`
- **Requires:**
  - intervals-in-state ≥ startup-duration (2 for gas/hydro, 6 for coal, 24 for nuclear)
- **Ensures:** state becomes `online`, output-mw set to min-output, intervals-in-state resets

### trip-generator

- **When:** generator is `online`
- **Ensures:** state becomes `tripped`, output-mw drops to 0, intervals-in-state resets

### stop-generator

- **When:** generator is `online`
- **Requires:** intervals-in-state ≥ min-up-time
- **Ensures:** state becomes `stopping`, output-mw ramps to 0 (within ramp-rate × 5)

### ramp-generator

Adjusts output of an online generator.

- **When:** generator is `online`
- **Requires:**
  - new output is within [min-output, max-output]
  - |new output − current output-mw| ≤ ramp-rate × 5
- **Ensures:** output-mw set to new value

## Invariants

### Generator physics (always hold)

1. **output-matches-state** — output-mw must be 0 when state is not `online`
2. **output-within-bounds** — when online: min-output ≤ output-mw ≤ max-output
3. **positive-capacity** — max-output > 0 and min-output ≥ 0 and min-output < max-output
4. **ramp-rate-positive** — ramp-rate > 0
5. **min-times-positive** — min-up-time > 0 and min-down-time > 0
6. **emissions-non-negative** — emissions-rate ≥ 0; emissions-rate = 0 iff fuel-type in {hydro, wind, solar}
7. **nuclear-constraints** — if fuel-type = nuclear: min-up-time ≥ 24 and min-down-time ≥ 48 and min-output ≥ 0.5 × max-output

### Storage physics

8. **soc-in-bounds** — min-soc ≤ soc ≤ max-soc
9. **rate-matches-state** — idle → current-rate = 0; charging → current-rate < 0; discharging → current-rate > 0
10. **rate-within-limits** — |current-rate| ≤ max-charge-rate (when charging) or max-discharge-rate (when discharging)
11. **efficiency-valid** — 0 < round-trip-efficiency ≤ 1.0
12. **soc-limits-ordered** — 0 ≤ min-soc < max-soc ≤ 1.0
13. **no-hunting** — if state = charging, previous state was idle or charging (not discharging); likewise for discharging. (Enforced structurally by not allowing direct charge↔discharge transitions.)
14. **soc-after-valid** — soc-after-interval must remain within [min-soc, max-soc]. This catches cases where the current rate would push SOC out of bounds within one interval.

### Demand-response ordering

15. **curtailment-priority-order** — within a grid-zone: no tier-N contract may be curtailed while any tier-(N-1) contract in the same zone is on standby. (Tier 1 curtailed before tier 2, tier 2 before tier 3.)
16. **notification-respected** — a contract in `curtailed` state must have spent ≥ min-notification-intervals in `notified` before transitioning.
17. **max-curtailment-duration** — if curtailed: intervals-in-state ≤ max-curtailment-intervals
18. **compensation-positive** — compensation-rate > 0

### Grid balance (dispatch-interval level)

19. **cleared-means-balanced** — if dispatch-interval state is `cleared`: |system-imbalance-mw| ≤ 50
20. **frequency-reflects-imbalance** — system-frequency-hz must be within 60.0 ± (system-imbalance-mw × 0.001). (1 MW imbalance ≈ 0.001 Hz deviation.)
21. **reserve-margin-sane** — if `cleared`: reserve-margin-pct ≥ 15
22. **emergency-threshold** — if state is `emergency`: reserve-margin-pct < 15 OR |system-imbalance-mw| > 50
23. **blackout-means-exhausted** — if state is `blackout`: all demand-response tiers are curtailed AND no generator can increase output
24. **emissions-match** — emissions-tons = Σ(generator.output-emissions) across all zones
25. **cost-match** — total-cost = Σ(generator.output-cost) + Σ(curtailed contract compensation) across all zones

### Cross-entity sanity

26. **generation-totals-consistent** — total-generation-mw = Σ(generator.output-mw) across all zones
27. **transfer-limits-respected** — for each grid-zone: if transfer-mw > 0 (importing), transfer-mw ≤ import-limit-mw; if < 0 (exporting), |transfer-mw| ≤ export-limit-mw
28. **transfer-net-zero** — Σ(grid-zone.transfer-mw) across all zones = 0 (conservation: what one zone imports, another exports)

## PBT strategy

This spec is deliberately hard to generate valid instances for. Key challenges:

**Generator state consistency:** Generators in `online` state need output within [min-output, max-output]. Generators not online must have output = 0. Nuclear has tighter constraints. The generator for the `generator` entity must select state and then set output accordingly — not independently.

**Storage state consistency:** current-rate sign must match state (positive for discharging, negative for charging, zero for idle). SOC must remain valid after applying the rate for one interval. The generator must compute soc-after-interval and verify it won't violate bounds.

**Curtailment priority ordering:** Generating a valid grid-zone with demand-response contracts requires ensuring no tier-N is curtailed while tier-(N-1) is on standby. The generator must sort contracts by tier and assign activation states monotonically.

**Dispatch-interval balance:** The hardest. A cleared dispatch requires imbalance within ±50 MW. The generator must:
1. Pick a demand, then set generator outputs and storage rates to approximately match it
2. Verify frequency is consistent with imbalance
3. Verify reserve margin ≥ 15%

This requires a composite generator that builds an entire grid scenario:
1. Create grid zones with realistic demand
2. For each zone, create generators (some online, some offline) with valid states
3. Set online generator outputs to approximately meet demand
4. Add storage units that fine-tune the balance
5. Add demand-response contracts with consistent priority ordering
6. Compute all derived fields from the constructed scenario

**Temporal constraints (min up-time, min down-time):** intervals-in-state must be consistent with state. A generator that's online must have intervals-in-state ≥ 0. For PBT, we just validate the snapshot — but the invariants still catch bad states (e.g., a generator claimed to be `stopping` with intervals-in-state = 0 and output > 0).

### Suggested generator approach

```
1. Pick number of zones (1–3)
2. For each zone:
   a. Set demand (100–2000 MW)
   b. Create 3–8 generators: pick fuel types, set capacities
   c. Decide which are online/offline respecting min-time constraints
   d. Set online generator outputs to sum ≈ demand × 0.9
   e. Create 0–2 storage units to handle the remaining ≈ 10%
   f. Create demand-response contracts, assign tiers, set activation states respecting priority order
3. Sum everything up into dispatch-interval fields
4. Compute frequency from imbalance
5. Determine dispatch state from reserve margin and balance
```
