Model an aircraft weight and balance system.

Entities:
- aircraft — has an id, registration (string), type (single-engine, twin-engine, or turboprop), basic-empty-weight (number, the aircraft's empty weight in lbs), basic-empty-moment (number, the empty moment in lb-ins), max-takeoff-weight (number), max-landing-weight (number), max-zero-fuel-weight (number), forward-cg-limit (number, inches aft of datum), and aft-cg-limit (number, inches aft of datum). An aircraft has many load-items and one fuel-load.
- load-item — has an id, description (string), weight (number in lbs), arm (number, inches aft of datum), a category (pilot, passenger, baggage, or cargo), and a zone (forward, aft, left, or right). Belongs to an aircraft. Has a derived moment field equal to weight * arm.
- fuel-load — has an id, fuel-weight (number in lbs), fuel-arm (number, inches aft of datum), max-fuel-capacity (number in lbs), burn-rate (number, lbs per hour), and flight-time (number, hours). Belongs to an aircraft. Has a derived fuel-moment field equal to fuel-weight * fuel-arm, and a derived landing-fuel-weight field equal to fuel-weight minus burn-rate * flight-time.
- cg-envelope — has an id, a reference-weight (number in lbs), forward-limit (number, inches), and aft-limit (number, inches). Belongs to an aircraft. Represents one point in the CG envelope polygon — aircraft will have many of these, but for spec purposes we model each point independently.
- dispatch — has an id, a state (draft, computed, approved, rejected) defaulting to draft, pilot-in-command (string), total-weight (number), total-moment (number), cg-position (number), landing-weight (number), and landing-cg (number). Belongs to an aircraft.

Rules:
- compute-dispatch — fires when a dispatch is in draft state. Requires: the aircraft has at least one load-item (pilot), fuel-weight is positive, and flight-time is positive. Ensures: state becomes computed, total-weight is set, total-moment is set, and cg-position is set.
- approve-dispatch — fires when a dispatch is in computed state. Requires: total-weight does not exceed the aircraft's max-takeoff-weight, landing-weight does not exceed max-landing-weight, cg-position is between the aircraft's forward-cg-limit and aft-cg-limit (inclusive), and landing-cg is between forward-cg-limit and aft-cg-limit (inclusive). Ensures: state becomes approved.
- reject-dispatch — fires when a dispatch is in computed state. Requires: total-weight exceeds max-takeoff-weight, or landing-weight exceeds max-landing-weight, or cg-position is outside the CG limits. Ensures: state becomes rejected.
- recompute-dispatch — fires when a dispatch is in computed or rejected state. Ensures: state becomes draft (allows re-editing and recomputation).

Invariants:
1. moment-is-weight-times-arm — on load-item: moment must equal weight * arm.
2. fuel-moment-correct — on fuel-load: fuel-moment must equal fuel-weight * fuel-arm.
3. landing-fuel-correct — on fuel-load: landing-fuel-weight must equal fuel-weight minus burn-rate * flight-time.
4. fuel-within-capacity — on fuel-load: fuel-weight must be >= 0 and <= max-fuel-capacity.
5. landing-fuel-non-negative — on fuel-load: landing-fuel-weight must be >= 0 (can't land with negative fuel).
6. positive-weights — on load-item: weight must be > 0.
7. cg-limits-ordered — on aircraft: forward-cg-limit must be less than aft-cg-limit.
8. weight-limits-ordered — on aircraft: max-landing-weight must be <= max-takeoff-weight.
9. approved-within-limits — on dispatch: if state is approved, then total-weight must be > 0, landing-weight must be > 0, and landing-weight must be <= total-weight.
10. dispatch-cg-sane — on dispatch: if state is approved or computed, then cg-position must be > 0.

After defining everything, validate the specs, define appropriate generators to handle cross-field dependencies, then run PBT with 500 trials.
