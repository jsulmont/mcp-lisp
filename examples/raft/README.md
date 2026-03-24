# Raft Consensus — Behavioral Specification

A behavioral spec of the [Raft consensus algorithm](https://raft.github.io/), translated from Diego Ongaro's [TLA+ formalization](https://github.com/ongardie/raft.tla/blob/master/raft.tla) into the mcp-lisp spec DSL with property-based testing.

## What was produced

`raft-spec.lisp` contains:

- **2 entities**: `server` (cluster node with state machine) and `log-entry` (replicated log entries with term, index, value)
- **8 state-machine rules**: `timeout-from-follower`, `timeout-from-candidate`, `become-leader`, `step-down-from-leader`, `step-down-from-candidate`, `restart-from-leader`, `restart-from-candidate`, `restart-from-follower`
- **6 per-entity invariants**: field bounds on term, commit-index, log-length (server) and idx, term (log-entry)
- **8 cross-entity invariants** on a `raft-cluster` scenario (3-5 servers + 0-50 log entries):

| Invariant | Raft safety property | What it checks |
|---|---|---|
| `election-safety` | Election Safety (sect 5.2) | At most one leader per term |
| `log-matching` | Log Matching (sect 5.3) | Same (index, term) across servers implies same value |
| `log-term-monotonicity` | Leader Append-Only (sect 5.3) | Terms non-decreasing within each server's log |
| `committed-prefix-agreement` | Leader Completeness / State Machine Safety (sect 5.4) | Committed prefixes identical across all servers |
| `entry-term-bounded` | Term consistency | No log entry has a term exceeding its server's current term |
| `log-length-consistent` | Structural integrity | Server's `log-length` field matches actual entry count |
| `log-indices-unique-per-server` | Log well-formedness | No duplicate indices within a server's log |
| `log-indices-contiguous` | Log well-formedness | Indices form 1..n with no gaps |

- **Custom scenario generator** (`defscenario-generator`): builds a shared committed prefix (same terms + values at each index across all servers), then appends divergent uncommitted tails. Uses a canonical `(idx, term) -> value` hash table so log-matching holds even across uncommitted entries. Tracks leader terms in a list to enforce election-safety during generation.
- **Targeted negative generator** (`defscenario-negative-generator`): 7 violation classes — two leaders same term, same index+term with different values, non-contiguous indices, entry term exceeding server term, log-length mismatch, non-monotonic terms, and committed prefix disagreement.

## How it was built — step by step

The entire spec was built in a single conversation loop using the mcp-lisp `eval_lisp` tool and the workflow prescribed in `CLAUDE.md`. Here is every step, in order:

### 1. Fetch the TLA+ source

**Tool**: `WebFetch` on `https://raw.githubusercontent.com/ongardie/raft.tla/master/raft.tla`

Retrieved the complete 300+ line TLA+ specification. Key structures extracted:
- Server variables: `currentTerm`, `state`, `votedFor`, `log`, `commitIndex`, `votesResponded`, `votesGranted`, `nextIndex`, `matchIndex`
- Actions: `Timeout`, `RequestVote`, `BecomeLeader`, `ClientRequest`, `AdvanceCommitIndex`, `AppendEntries`, `HandleRequestVoteRequest/Response`, `HandleAppendEntriesRequest/Response`, `UpdateTerm`, `Restart`
- Implicit safety properties: election safety, log matching, leader append-only, leader completeness, state machine safety

### 2. Read the DSL reference

**Tool**: `Read` on `etc/spec-reference.md`

Loaded the full spec DSL API to understand `defentity`, `defrule`, `definvariant`, `defscenario`, `defscenario-generator`, `defscenario-negative-generator`, and the PBT runner.

### 3. Define entities

**Tool**: `eval_lisp` — `clear-specs`, `defentity server`, `defentity log-entry`

Mapped TLA+ variables to two entities. Simplified the model: `log-length` replaces the full log sequence on server, individual `log-entry` records carry `server-id`, `idx`, `term`, `value`. The `has-many`/`belongs-to` relation links them.

### 4. Define per-entity invariants

**Tool**: `eval_lisp` — 6x `definvariant`

Encoded field bounds: `term >= 1`, `commit-index >= 0`, `commit-index <= log-length`, `log-length >= 0`, `entry.idx >= 1`, `entry.term >= 1`.

### 5. Define state-machine rules

**Tool**: `eval_lisp` — 8x `defrule`

Translated TLA+ actions into state-machine rules with `:when`/`:ensures`/`:sets`. The TLA+ `Timeout` (which applies to both follower and candidate) became two rules since `:when` takes a single state. `Restart` from each state and `step-down` from leader/candidate round out the transitions.

### 6. Verify state machine

**Tool**: `eval_lisp` — `analyze-state-machine "server"`

Confirmed: 3 states, all reachable, no terminal states (correct — Raft servers run indefinitely), 8 transitions matching the TLA+ spec.

### 7. Define scenario and cross-entity invariants

**Tool**: `eval_lisp` — `defscenario raft-cluster`, 8x `definvariant`

The scenario binds `servers (3 5)` and `entries (0 50)`. Each invariant iterates over the bindings to check a Raft safety property. The `committed-prefix-agreement` invariant uses nested loops over server pairs to verify that committed log prefixes are identical.

### 8. Check completeness

**Tools**: `eval_lisp` — `list-entities`, `list-rules`, `list-invariants`, `list-scenarios`, `invariant-coverage`, `generation-feasibility`, `scenario-feasibility`

- Invariant coverage: all constrained fields covered; `id`, `voted-for`, `server-id`, `value` intentionally uncovered
- Scenario feasibility: `:needs-custom-generator` (all 8 scenario invariants use aggregates over correlated data)

### 9. Write custom scenario generator (attempt 1)

**Tool**: `eval_lisp` — `defscenario-generator raft-cluster`

First attempt used a single `leader-term` variable and a canonical hash table. Hit a CL `loop` syntax error (`do` followed by `for` — iteration clause after body code). Fixed by moving the side effect into the `for state =` binding.

### 10. First PBT run — 500 trials

**Tool**: `eval_lisp` — `run-pbt :trials 500 :negative-trials 200`

Result: **325/500 failures** on `committed-prefix-agreement`. Root cause: the generator created independent random log entries per server. Two servers with committed entries at the same index could have different terms/values.

### 11. Rewrite generator with shared committed prefix

**Tool**: `eval_lisp` — `defscenario-generator raft-cluster` (rewrite)

New design: generate a shared committed log prefix (sorted terms, shared values), give every server that prefix, then append divergent uncommitted tails using the canonical hash table for log-matching consistency.

### 12. Second PBT run — 500 trials

**Tool**: `eval_lisp` — `run-pbt :trials 500 :negative-trials 200`

Result: **10/500 failures** on `election-safety`. Root cause: `leader-term` tracked only the most recent leader's term. If server A became leader at term 3, then server B at term 5, server C could also become leader at term 3 (check was `= term leader-term` which was 5, not 3).

### 13. Fix generator — track all leader terms

**Tool**: `eval_lisp` — `defscenario-generator raft-cluster` (fix)

Changed `leader-term` (single value) to `leader-terms` (list). Check became `(member server-term leader-terms)`.

### 14. Third PBT run — all green

**Tool**: `eval_lisp` — `run-pbt :trials 500 :negative-trials 200`

Result: **500/500 pass**. All per-entity and scenario invariants hold. Negative testing validated for 13/14 invariants (1 structurally untestable — UUID uniqueness).

### 15. Write targeted negative generator

**Tool**: `eval_lisp` — `defscenario-negative-generator raft-cluster`

7 violation classes covering all scenario invariants including `committed-prefix-agreement` (which random negatives couldn't reach).

### 16. Final PBT run — 500 positive, 300 negative

**Tool**: `eval_lisp` — `run-pbt :trials 500 :negative-trials 300`

Result: **1500/1500 positive pass**. Negative rejection rates: all invariants now reject bad data (committed-prefix-agreement at 7% via targeted generator). Only `log-indices-unique-per-server` remains structurally untestable (UUID collision probability ~0).

### 17. Random walk — server state machine

**Tool**: `eval_lisp` — `random-walk "server" :steps 20 :trials 50`

Result: **50/50 pass**. 20-step random rule sequences maintain all per-entity invariants.

### 18. Save spec

**Tool**: `eval_lisp` — `(specs-to-lisp)` with `file_path`

Wrote the canonical loadable spec to `raft-spec.lisp` (344 lines).

## Reloading the spec

```lisp
(clear-specs)
(load "raft-spec.lisp")
(run-pbt :trials 500 :negative-trials 200)
```
