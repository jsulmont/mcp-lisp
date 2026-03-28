## Micro-specs

Targeted, minimal domain prompts (2-4 entities) designed to stress-test specific DSL capabilities. Each micro-spec starts from a plain-English domain description and produces a spec via the normal workflow.

### Purpose

Unlike `examples/`, these are not about modeling a full domain. They exist to:

1. Expose DSL gaps organically — by speccing from a naive prompt, not a pre-filtered one
2. Validate fixes after gaps are addressed
3. Serve as regression tests for DSL capabilities

The gap is the delta between what the prompt asks for and what the spec can actually express.

### Structure

Each subdirectory contains:

- `PROMPT.md` — the domain description in plain English, written as a domain expert would describe it, not as someone who knows the DSL
- `<name>-spec.lisp` — the spec produced by following the `examples/CLAUDE.md` workflow against the prompt

The prompt is the input. The spec is the output. Do not hand-tune prompts to avoid known gaps — the whole point is to hit them.

### Workflow

Start Claude from the **repo root** (`~/dev/mcp-lisp`). The `eval_lisp` MCP tool runs in the Lisp process whose working directory is the repo root.

1. Read `PROMPT.md` for the target micro-spec
2. Follow the standard `examples/CLAUDE.md` workflow to produce a spec
3. When the DSL can't express something the prompt asks for, note it in a `FINDINGS.md` in the micro-spec directory
4. Save the spec: `(specs-to-lisp)`, write to `<name>-spec.lisp`
5. Run full PBT including scenarios

### FINDINGS.md format

```markdown
## Findings

### <gap title>
- **What the prompt asks for**: <plain English>
- **What the DSL can express**: <what was actually written>
- **Workaround**: <what the generator/scenario had to do, or "none">
- **Suggested fix**: <what DSL change would close the gap>
```

### Adding a new micro-spec

Write a PROMPT.md as a domain expert would — short (1-3 paragraphs), concrete, no DSL jargon. Pick a domain that naturally requires patterns you suspect the DSL handles poorly. Name the directory after the domain, not the gap.
