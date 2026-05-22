---
name: write-a-skill
description: Create new agent skills with proper structure, frontmatter triggers, and progressive disclosure. Use when user wants to create, write, or build a new skill, or when adding a new entry under .opencode/skills/ or .agents/skills/.
---

<!--
Adapted from mattpocock/skills (MIT, https://github.com/mattpocock/skills/blob/main/skills/productivity/write-a-skill/SKILL.md).
Rewritten to fit this repo's dual skill-tier layout (.opencode/skills + .agents/skills) and Trellis spec system.
-->

# Writing Skills

## Where the new skill lives

Two tiers in this repo:

| Tier | Path | When to put a skill here |
|------|------|--------------------------|
| Platform-specific | `.opencode/skills/<name>/` | OpenCode-only, ties to opencode tooling, or wraps Trellis workflows (`trellis-*`). |
| Cross-platform | `.agents/skills/<name>/` | Works in any agent platform (claude / codex / opencode), no opencode-specific paths. |

When unsure, prefer `.agents/skills/` so Codex / Claude users can also load it.

## Process

1. **Trigger discovery** — ask user:
   - What task/scenario triggers this skill? (Match the existing `description` style: "Use when ...")
   - Which Trellis package(s) does it apply to? (rust-core / flutter-app / cross-language / build-and-release)
   - Does it need bundled scripts, reference files, or just instructions?
   - Does it call existing project commands (`flutter test`, `cargo test --workspace`, `bash build_android_debug.sh`)?

2. **Draft SKILL.md** — frontmatter + body:
   ```md
   ---
   name: skill-name
   description: First sentence: what it does. Second sentence: Use when [specific triggers].
   ---

   <!-- Optional: attribution if adapted from upstream skill -->

   # Skill Name

   ## Quick start
   [Minimal working example]

   ## Workflow
   [Step-by-step with checkboxes for complex tasks]

   ## References
   [Link to .trellis/spec/<package>/<topic>.md when relevant]
   ```

3. **Spec linkage** — every skill that touches code MUST cite the relevant `.trellis/spec/` doc(s) so loaded context already contains project conventions. Don't duplicate spec content; link to it.

4. **Review with user** — present draft, ask:
   - Triggers cover real cases?
   - Anything redundant with existing trellis-* / flutter-* skills?
   - Should the skill load `.trellis/spec/<package>/index.md` first?

5. **Test the description** — read the description out loud against 3 sibling skills. Can you tell which one to load? If two could match, sharpen the trigger words.

## Description requirements

The description is **the only thing the host LLM sees** when deciding which skill to load. It surfaces in the system prompt alongside all other installed skills.

Format:
- Max 1024 chars (description tokens count toward system prompt budget every turn)
- Third person
- First sentence: what it does
- Second sentence: "Use when [specific triggers]" — keyword-rich

Good: `Configure Flutter Driver for app interaction and convert MCP actions into permanent integration tests. Use when adding integration testing, exploring UI components via MCP, or automating user flows.`

Bad: `Helps with testing.`

## When to add scripts vs. text

Add `scripts/` when:
- Operation is deterministic (validation, formatting, regen FRB binding)
- Same code would be generated repeatedly
- Errors need explicit handling

Otherwise prose suffices. This repo's existing skills use prose-only — scripts are rare.

## When to split into multiple files

Split into `REFERENCE.md` / `EXAMPLES.md` when:
- SKILL.md exceeds 100 lines
- Content has distinct domains (e.g. `trellis-meta` references/ tree)
- Advanced features rarely needed (progressive disclosure)

Existing examples in repo:
- Tiny: `.opencode/skills/trellis-meta/SKILL.md` body delegates to references/
- Medium: `.agents/skills/flutter-add-widget-test/SKILL.md` self-contained ~70 lines

## Review checklist

- [ ] Description has "Use when ..." triggers
- [ ] SKILL.md body under 100 lines (overflow into REFERENCE.md)
- [ ] No time-sensitive info ("as of Q1 2026" decays)
- [ ] Consistent terminology with `.trellis/spec/index.md` glossary
- [ ] Concrete examples with file_path:line_number (matches repo's reporting style)
- [ ] References one level deep — don't link skills that link skills
- [ ] Attribution comment if adapted from upstream
- [ ] If platform-specific tooling: lives under `.opencode/skills/`
- [ ] If cross-platform: lives under `.agents/skills/`

## Trellis-specific patterns

When the new skill participates in the Trellis workflow (PRD → implement → check → archive), reference:

- `.trellis/workflow.md` — phase boundaries
- `.trellis/spec/<package>/index.md` — per-package spec entry point
- `.opencode/skills/trellis-before-dev/SKILL.md` — pre-dev context injection (skills that run before dev should align with this)
- `.opencode/skills/trellis-update-spec/SKILL.md` — when the new skill discovers a convention worth preserving

When the new skill is a simple reusable trigger (like `caveman` / `zoom-out`), keep it in `.agents/skills/` and don't entangle with Trellis.
