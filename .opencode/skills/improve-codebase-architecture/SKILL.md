---
name: improve-codebase-architecture
description: Find deepening opportunities in a codebase, informed by the project glossary in .trellis/spec/ and decisions logged in master findings. Use when the user wants to improve architecture, find refactoring opportunities, consolidate tightly-coupled modules, or make a codebase more testable and AI-navigable.
---

<!--
Adapted from mattpocock/skills (MIT, https://github.com/mattpocock/skills/blob/main/skills/engineering/improve-codebase-architecture/SKILL.md).
Rewritten to fit this repo's `.trellis/` task system (markdown report under tasks/<active>/research/, no HTML), `.trellis/spec/` glossary instead of CONTEXT.md, and findings.md as ADR substitute.
-->

# Improve Codebase Architecture

Surface architectural friction and propose **deepening opportunities** — refactors that turn shallow modules into deep ones. Aim: testability + AI-navigability.

## Glossary (use these exactly)

Use these terms in every suggestion. Don't drift into "component," "service," "API," or "boundary." Full definitions in [LANGUAGE.md](LANGUAGE.md).

- **Module** — anything with an interface + an implementation (function, class, crate, layer).
- **Interface** — everything a caller must know: types, invariants, error modes, ordering, config. Not just the type signature.
- **Implementation** — code inside.
- **Depth** — leverage at the interface: large behaviour behind small interface. **Deep** = high leverage. **Shallow** = interface ≈ implementation in complexity.
- **Seam** — where an interface lives; alteration point without editing in place.
- **Adapter** — concrete satisfier of an interface at a seam.
- **Leverage** — what callers gain from depth.
- **Locality** — what maintainers gain from depth: change/bugs/knowledge concentrated at one place.

Key principles:
- **Deletion test**: delete the module mentally. If complexity vanishes, it was a pass-through. If complexity reappears across N callers, it was earning keep.
- **The interface is the test surface.**
- **One adapter = hypothetical seam. Two adapters = real seam.**

This skill is _informed_ by the project's domain model. The glossary in `.trellis/spec/index.md` (and per-package `.trellis/spec/<package>/index.md`) gives names to good seams; master findings under `.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings*.md` record decisions the skill should not re-litigate.

## Process

### 1. Explore

Read first:
- `.trellis/spec/index.md` + relevant package spec (e.g. `.trellis/spec/rust-core/quality-and-anti-patterns.md` or `.trellis/spec/flutter-app/quality-and-anti-patterns.md`)
- master findings: `.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md` + the per-wave finding file for the area you're touching

Then walk the codebase organically (use Task tool with explore subagent if available). Note where you experience friction:

- Where does understanding one concept require bouncing between many small modules?
- Where are modules **shallow** — interface ≈ implementation?
- Where have pure functions been extracted just for testability, but real bugs hide in how they're called (no **locality**)?
- Where do tightly-coupled modules leak across their seams?
- Which parts are untested or hard to test through their current interface?

Apply the **deletion test** to anything you suspect is shallow.

### 2. Present candidates as a markdown report

Write to the **active task's research directory** (consistent with this repo's BATCH 报告流):
```
.trellis/tasks/<active-task>/research/architecture-review-<YYYY-MM-DD>.md
```

If no active task: create one via the brainstorm skill (`trellis-brainstorm`) first, or write to `.trellis/workspace/<user>/scratch/architecture-review-<ts>.md` and **say so** to the user.

**Don't write HTML.** Reasons: this repo's reports are all markdown (BATCH PRDs / findings.md), browsers aren't always available, markdown survives `git diff` review.

For each candidate, render a section:

```markdown
## Candidate N: <short name>

**Files**: `core/core-source/src/parser.rs:1294-1297` + 4 callers

**Recommendation**: Strong | Worth exploring | Speculative

**Problem**: Why current architecture creates friction. Use deletion test result if shallow.

**Solution**: Plain English description of what changes.

**Benefits** (locality + leverage): How tests improve. Which fix-once concentrates which N caller fixes.

**Before / After** (text diagram, ascii-box style or mermaid in fenced ```mermaid block):
\`\`\`
Before: caller_A → adapter_A
        caller_B → adapter_B  → impl
        caller_C → adapter_C
                          (3 shallow, leak through)
After:  caller_A ┐
        caller_B ┼→ deep_module
        caller_C ┘
\`\`\`

**Conflicts with existing decision?**: cite finding ID (e.g. `F-W1B-006 Resolved-by-Design BATCH-10`) and explain why friction is real enough to revisit.
```

End with:
```markdown
## Top recommendation

Tackle **<candidate name>** first because <leverage + locality reason>.
```

**Use spec vocabulary for the domain, glossary above for the architecture.** If `.trellis/spec/rust-core/quality-and-anti-patterns.md` defines "RuleContext", talk about "the RuleContext clone path" — not "the FooBarHandler" or "the rule service."

**Conflict with existing finding/spec**: when a candidate contradicts a Resolution recorded in master findings (e.g. `F-W1B-006 Resolved-by-Design`), surface only when friction is real enough to revisit. Mark with a callout: `> ⚠️ contradicts F-W1B-006 Resolved-by-Design — but worth reopening because <new evidence>`. Don't list every theoretical refactor a finding forbids.

After writing, **ask the user**: "Which of these would you like to explore?" Don't propose interfaces yet.

### 3. Grilling loop

Once user picks a candidate, drop into a grilling conversation. Walk the design tree — constraints, dependencies, deepened module shape, what sits behind the seam, what tests survive.

Side effects happen inline as decisions crystallize:

- **Naming a deepened module after a concept not in `.trellis/spec/`?** Add it to the relevant package spec (`.trellis/spec/<package>/index.md` glossary section, or a dedicated topic doc). Use `trellis-update-spec` skill workflow.
- **Sharpening a fuzzy term during conversation?** Update the spec right there.
- **User rejects with a load-bearing reason?** Offer to record it as a Resolved-by-Design Resolution on the relevant finding (or create a new finding-style entry under the active task's research/). Frame as: "Want me to record this so future architecture reviews don't re-suggest it?" Only offer when the reason would actually be needed by a future explorer to avoid re-suggesting the same thing — skip ephemeral reasons ("not worth it right now") and self-evident ones.
- **Want to explore alternative interfaces for the deepened module?** See [INTERFACE-DESIGN.md](INTERFACE-DESIGN.md) (sketches before commitment).

## Trellis integration

This skill complements (does not replace):
- `trellis-spec-bootstarp` — bootstraps spec from scratch on a new package
- `trellis-update-spec` — captures one specific convention learned during dev
- `trellis-break-loop` — root-causes a recurring bug; this skill finds shallow modules that *would* breed bugs

Use `improve-codebase-architecture` once every few BATCH cycles to catch entropy, not on every change.
