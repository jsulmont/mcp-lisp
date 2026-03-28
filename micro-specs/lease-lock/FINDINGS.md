## Findings

### Time-triggered transitions
- **What the prompt asks for**: "When the lease duration elapses, the holding node transitions to expired and the lease is released" — expiration is triggered by wall-clock time exceeding grant-time + duration.
- **What the DSL can express**: `expire-lease` is an event-based rule that can fire whenever a node is in `:holding`. There is no way to express "fire this rule when current-time > grant-time + duration".
- **Workaround**: Modeled as an unconstrained rule with `:when (node :state :holding)`. The temporal trigger is lost — the rule can fire at any time, not only after the duration elapses.
- **Suggested fix**: Support temporal guards on rules, e.g. `:after (elapsed-since (lease-grant-time lease) (lease-duration lease))`, so the engine can model time-triggered transitions and PBT can verify them.

### Cross-entity rule guards
- **What the prompt asks for**: "An idle node may request the lease if no other node currently holds a valid (non-expired) lease" — the request guard depends on the state of the lease (and transitively, all sibling nodes).
- **What the DSL can express**: The `:requires` clause can reference fields on related entities via `:let` bindings (e.g. traversing belongs-to), so `(null (lease-holder-id lease))` is partially expressible. However, the "valid (non-expired)" check requires temporal reasoning (see above).
- **Workaround**: The guard is omitted from the rule. Mutual exclusion is enforced only as a scenario invariant, not as a rule precondition. The random-walk can therefore produce traces where `request-lease` fires while another node holds a valid lease.
- **Suggested fix**: This is mostly a consequence of the time-triggered gap. With temporal guards, the cross-entity guard could be fully expressed via `:let` + `:requires`.
