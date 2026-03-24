# Feature Gaps

## Cross-entity rule triggers

Rules are single-entity scoped. Protocol specs are dominated by message handlers where server state changes in response to a message's fields. The current DSL can't express guards like:

```lisp
;; TLA+: m.mterm > currentTerm[i]
;; Desired (not currently possible):
(defrule update-term
  :when (server :state (member :follower :candidate :leader))
  :given (message m)  ;; <-- no such clause
  :requires ((> (message-mterm m) (server-current-term server)))
  :sets ((server-current-term server) (message-mterm m))
  :ensures ((eq (server-state server) :follower)))
```

`:let`/`:requires` can reference related entities via `has-many`/`belongs-to`, but there's no way to bind an arbitrary entity instance that triggers the rule. This forces approximations (e.g., incrementing term by 1 instead of adopting the message's term).

Possible extension: a `:given` or `:trigger` clause that binds a second entity, making the rule a two-entity interaction.

## Set field type

TLA+ uses sets extensively (`votesResponded`, `votesGranted` are sets of server IDs). These must be modeled as integer counters, which loses key semantics:

- **Idempotency**: Adding an already-present element to a set is a no-op. Incrementing a counter is not. Random-walk can over-count.
- **Natural bounding**: Set cardinality is bounded by the universe. Counter requires manual `:requires` guards.
- **Membership testing**: `j ∈ votesResponded[i]` has no analog. Had to approximate with `votes-responded-count < cluster-size`.

A `set` field type with operations like `add`, `contains`, `cardinality`, and `elements` would map directly to protocol specs and avoid these approximations.

```lisp
;; Hypothetical:
(defentity server ()
  ...
  (votes-responded (set-of string) :default (empty-set))
  (votes-granted (set-of string) :default (empty-set)))

(defrule handle-request-vote-response
  :when (server :state (member :follower :candidate :leader))
  :sets ((server-votes-responded server) (set-add (server-votes-responded server) sender-id)
         (server-votes-granted server) (set-add (server-votes-granted server) sender-id)))

(definvariant votes-bounded
  :on server
  :check (<= (set-cardinality (server-votes-granted server)) (config :cluster-size)))
```
