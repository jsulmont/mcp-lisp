# Raft Leader Election — Spec from TLA+

Translate the **leader election** subset of the Raft consensus protocol into a behavioral spec using the DSL. The source of truth is `raft.tla` in this directory (Ongaro's TLA+ specification, CC BY 4.0).

## Scope

Leader election only. Specifically these TLA+ actions:

- `Timeout(i)` — follower/candidate starts new election
- `RequestVote(i, j)` — candidate sends vote request
- `HandleRequestVoteRequest(i, j, m)` — server handles incoming vote request
- `HandleRequestVoteResponse(i, j, m)` — candidate tallies vote response
- `BecomeLeader(i)` — candidate with quorum becomes leader
- `UpdateTerm(i, j, m)` — step down on higher term
- `Restart(i)` — server crashes and restarts
- `DropStaleResponse(i, j, m)` — ignore stale responses

**Out of scope** for this spec: `AppendEntries`, `HandleAppendEntriesRequest/Response`, `ClientRequest`, `AdvanceCommitIndex`, log replication, commit index advancement.

## Entities

From the TLA+ variables:

- **server** — `currentTerm` (integer), `state` (follower/candidate/leader), `votedFor` (string, nullable), `votesResponded` (set-of server IDs), `votesGranted` (set-of server IDs). `log` and `commitIndex` are out of scope.
- **message** — the message pool. Fields: `mtype` (request-vote-request/request-vote-response), `mterm` (integer), `msource` (string), `mdest` (string), `mvote-granted` (boolean, only for responses), `mlast-log-term` (integer), `mlast-log-index` (integer).

## Rules

Map each TLA+ action to a `defrule`. Every field the TLA+ action mutates must appear in `:sets` or `:ensures`. Use `:after` for the election timeout. Use `:creates` for sending messages.

## Invariants

From the TLA+ spec and Raft paper:

1. **Election Safety** — at most one leader per term (scenario invariant across all servers)
2. **Vote Safety** — each server votes for at most one candidate per term (per-server invariant: if votedFor is non-nil, it doesn't change within the same term)
3. **Term Monotonicity** — a server's currentTerm never decreases (per-server, across rule applications)
4. **Leader has quorum** — any server in state :leader must have received votes from a majority

## Scenario

A `raft-election` scenario with 3-5 servers and a message pool. Use `random-walk-scenario` as the main verification method — it exercises the full election protocol by walking through random sequences of timeouts, vote requests, and vote responses.

## Config

- `cluster-size` — number of servers (integer, 3-5)

## Deliverable

Follow the workflow in CLAUDE.md. Save the final spec via `(specs-to-lisp)` to `raft-election-spec.lisp` in this directory.
