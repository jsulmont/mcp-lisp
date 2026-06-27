# Extraction Pipeline — Claude Architect Exercise 3 (steps 1–3)

A structured-data extraction pipeline built **spec-native** on mcp-lisp: the
extraction target is a `defentity`, its JSON Schema is *derived* from that entity,
and extractions are validated with the spec engine's `check-invariants`.

All five steps are implemented; pick one with the run mode.

## Run

```sh
examples/extraction-pipeline/run.sh            # steps 1-3 (default: extract)
examples/extraction-pipeline/run.sh batch      # step 4: Message Batches API
examples/extraction-pipeline/run.sh review     # step 5: confidence + review routing
examples/extraction-pipeline/run.sh all        # everything
```

Key-gated: no-ops unless `ANTHROPIC_API_KEY` is set (env or project-root `.env`).
Uses `claude-opus-4-8` with **structured outputs**. (The `batch` run submits a
real Message Batch and polls until it ends — typically a minute or two for a
handful of docs.)

## Design — spec as the single source of truth

```
defentity publication ──► entity->extraction-schema ──► output_config.format  (the model's schema)
        │
        └──► check-invariants ◄── json->instance ◄── model's JSON response     (validation)
```

- The schema the model must satisfy is **derived from the entity** (`entity-fields`),
  so the tool schema and the validation rules can never drift apart.
- `(spec-json-schema)` is intentionally *not* used — it emits a meta-schema of the
  spec DSL, not a schema for a `publication` instance.

## How it maps to the steps

| Step | Requirement | Where |
|------|-------------|-------|
| 1 | Schema with required + optional, enum-with-`other`+detail, nullable; model returns `null` not fabrication | `defentity publication` (`:required`, `(member …)` incl. `:other` + `other-detail`, `:nullable`) → `entity->extraction-schema`. `null-audit` reports which nullable fields came back null. The **sparse-narrative** doc exercises it. |
| 2 | Validation-retry loop: on failure re-prompt with doc + failed extraction + specific error; track retryable vs not | `check-invariants` → `(:FAIL "name" …)` drives `extract-with-retry`; `*invariant-help*` turns invariant names into actionable feedback. Resolved-on-retry = was retryable; `:unresolved` after `*max-retries*` = treat as needs-review. A **forced-repair demo** seeds a known-bad extraction so the repair path always runs. |
| 3 | Few-shot across varied formats | `*system-prompt*` includes bibliography / inline-narrative / informal-missing examples. |
| 4 | Batch via Message Batches API; failures by `custom_id`; resubmit/chunk; time vs SLA | `submit-batch` → `poll-batch` → `batch-results` (parses the JSONL `results_url`); each result validated by `custom_id`; SLA math vs `*batch-sla-seconds*`; failed-id resubmit/chunk branch. |
| 5 | Field-level confidence; route low-confidence to review; accuracy by field | `confidence-schema` wraps the extraction with a per-field confidence map; `route-for-review` flags fields below `*confidence-threshold*`; `*gold-set*` drives accuracy-by-field. |

## Sample documents

- **full-bibliography** — all fields present → expect `(:PASS)`, nothing null.
- **sparse-narrative** — authors/year/venue/doi absent → expect those `null`.
- **tricky-other** — an internal postmortem → `pub_type: other` with `other_detail`.
- **forced-repair** — a seeded extraction with `pub_type:other` but no `other_detail`
  (violates `other-requires-detail`) → the repair turn fixes it.

## The invariants (semantic checks structured outputs can't enforce)

- `other-requires-detail` — `pub_type=other ⇒ other_detail` non-empty.
- `plausible-year` — `year` ∈ [1900, 2026] or `null`.

Because structured outputs guarantee *structure*, the realistic, retry-worthy
failures are these *semantic* violations — which is exactly what the spec engine
catches.

## Tweaks to try

- Add a field/invariant to `defentity publication`; the schema and validation
  update together with no other changes.
- Lower `*max-retries*` to 0 to see `:unresolved` routing.
