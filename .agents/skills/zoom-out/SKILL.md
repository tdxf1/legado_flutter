---
name: zoom-out
description: Tell the agent to zoom out and give broader context or a higher-level perspective on an unfamiliar section of code. Use when you're unfamiliar with a section of code or need a map of how it fits into the bigger picture.
---

<!--
Adapted from mattpocock/skills (MIT, https://github.com/mattpocock/skills/blob/main/skills/engineering/zoom-out/SKILL.md).
Rewritten to reference this repo's `.trellis/spec/` glossary instead of CONTEXT.md.
-->

I don't know this area of code well. Go up a layer of abstraction. Give me a map of all the relevant modules and callers.

Use the project's vocabulary from `.trellis/spec/index.md` and the package-specific spec under `.trellis/spec/<package>/`. If a term in this code matches a glossary entry (e.g. "RuleContext", "ReaderSettings", "ssrf_guard", "FRB funcId"), use that exact term.

For Rust core: name the crate (`core-source` / `core-storage` / `core-net` / `bridge`) + the FRB funcId if exposed.
For Flutter: name the layer (UI / Logic / Data) per `.trellis/spec/flutter-app/quality-and-anti-patterns.md`.
For cross-language: refer to `.trellis/spec/cross-language/frb-bridge.md` patterns (manual wire, funcId table, JSON-string contract).

End with the **3 most likely places** the next change would land, ranked.
