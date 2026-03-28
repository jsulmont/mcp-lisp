## Findings

### Conditional field validity (discriminated unions without variants)
- **What the prompt asks for**: Request messages have no response-result; response messages must have one; response-result must be consistent with payload vs threshold. These are conditional constraints based on msg-type.
- **What the DSL can express**: Per-entity invariants with `if` guards on msg-type. Works at the invariant level but the default generator ignores conditional dependencies — it produces random response-results for all message types.
- **Workaround**: Custom `defgenerator` for message that enforces conditional field logic (nil result for requests, payload-consistent result for responses).
- **Suggested fix**: A `:when` clause on fields or field-level constraints conditioned on another field's value, so the default generator can enforce them without a custom generator. Alternatively, variant support per msg-type would give each variant its own field set.

### No cross-entity FK for string-id references (false gap)
- **What the prompt asks for**: Message sender/receiver must reference existing nodes.
- **What the DSL can express**: `sender-id` and `receiver-id` as plain strings. The agent didn't use `belongs-to` because it assumed the DSL can't have two belongs-to on the same entity type.
- **Workaround**: Scenario generator manually wires node IDs into message fields. Scenario invariants assert the wiring.
- **Note**: This is actually supported — Raft uses `(:belongs-to leader :of server)` and `(:belongs-to follower :of server)` on the same entity. The agent could have written `(:belongs-to sender :of node)` and `(:belongs-to receiver :of node)`. This is a discoverability issue with `spec-reference`, not a DSL gap.

### Rules cannot be driven by related entity data
- **What the prompt asks for**: "When a request message is delivered to the responder, the responder must process it" and "the responder's decision depends on the message payload" — the rule that fires on the responder is caused by and conditioned on a message entity's fields.
- **What the DSL can express**: `deliver-request`, `respond-accept`, `respond-reject` are separate rules that guard only on the node's own state. There is no way to say "this rule fires because a message with payload >= threshold was delivered." The causal link between message content and responder behavior is lost from the rule definitions — it exists only as a scenario invariant on generated data.
- **Workaround**: Split the decision into two unconstrained rules (`respond-accept`, `respond-reject`) and enforce payload-decision consistency as an invariant. The spec verifies the *result* is correct but cannot model the *cause*.
- **Suggested fix**: Allow `:requires` or `:let` to bind and inspect related entities, e.g. `:let ((msg (pending-message-for node)))` then `:requires ((>= (message-payload msg) (config :threshold)))`. This would let rules express cross-entity causality, not just single-entity state guards.

### Negative testing blind spot for string inequality
- **What the prompt asks for**: Sender and receiver must differ.
- **What the DSL can express**: `sender-receiver-differ` invariant works correctly.
- **Workaround**: None needed for correctness, but negative testing reports 0% rejection because random string generation almost never produces two equal strings.
- **Suggested fix**: Negative generator could be made aware of inequality invariants and occasionally force field equality. Low priority — the invariant is still validated by positive PBT.
