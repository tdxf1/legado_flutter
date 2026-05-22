<!--
Adapted from mattpocock/skills (MIT, https://github.com/mattpocock/skills/blob/main/skills/engineering/improve-codebase-architecture/LANGUAGE.md).
Same vocabulary; reframed examples to this repo's modules (RuleContext / ssrf_guard / ReaderSettings / FRB funcId).
-->

# Language

Shared vocabulary for every suggestion this skill makes. Use these terms exactly — don't substitute "component," "service," "API," or "boundary." Consistent language is the whole point.

## Terms

**Module**
Anything with an interface and an implementation. Deliberately scale-agnostic — applies equally to a function (`is_url_safe_for_fetch`), a struct (`RuleContext`), a crate (`core-source`), or a tier-spanning slice (RSS detail page → FRB funcId 110 → `RssArticleDao::get_by_origin_link`).
_Avoid_: unit, component, service.

**Interface**
Everything a caller must know to use the module correctly. Includes the type signature, but also invariants, ordering constraints, error modes, required configuration, and performance characteristics.

Example: `LegadoHttpClient::get(url, headers, charset) -> Result<String, String>` — but the **interface** also includes "throws on SSRF guard reject", "follows redirects up to 5 hops", "10 MiB body cap", "honors `https_only(false)` business carve-out". All of that is part of what callers must know.

_Avoid_: API, signature (too narrow — those refer only to the type-level surface).

**Implementation**
What's inside a module — its body of code. Distinct from **Adapter**: a thing can be a small adapter with a large implementation (a `LegadoHttpClient` Postgres-style ureq wrapper) or a large adapter with a small implementation (an in-memory `setSecureStorageOverrideForTest` fake). Reach for "adapter" when the seam is the topic; "implementation" otherwise.

**Depth**
Leverage at the interface — the amount of behaviour a caller (or test) can exercise per unit of interface they have to learn. A module is **deep** when a large amount of behaviour sits behind a small interface. A module is **shallow** when the interface is nearly as complex as the implementation.

Example: `ssrf_guard::is_url_safe_for_fetch(&url) -> Result<(), SsrfError>` is **deep** — one fn call protects against 8+ host classes (loopback, RFC1918, link-local, CGNAT, multicast, cloud-metadata, IPv6 ::1, IPv4-mapped) plus scheme reject. The 4 callers (`java.ajax`, `java.downloadFile`, `queryTtf`, `LegadoHttpClient::request`) all gain protection through one tiny interface.

Counter-example: a `_normalizeJsResult(text)` that does `jsonDecode` with a `substring(1, len-1)` fallback — the interface is "decode JS result string", the impl mostly *is* that decode, no leverage. (BATCH-05 deepened it into `safeJsResultDecode` + structured fallback.)

**Seam** _(from Michael Feathers)_
A place where you can alter behaviour without editing in that place. The *location* at which a module's interface lives. Choosing where to put the seam is its own design decision, distinct from what goes behind it.

Example: `setSecureStorageOverrideForTest(SecureStorageImpl?)` exposes a seam at the secure_storage module so widget tests can inject a fake without touching the call sites in `webdav_config_page.dart`. The seam is a `SecureStorageImpl` abstract class with `read/write/delete`.

_Avoid_: boundary (overloaded with DDD's bounded context).

**Adapter**
A concrete thing that satisfies an interface at a seam. Describes *role* (what slot it fills), not substance (what's inside).

Example: `_RealSecureStorage` (Keystore-backed adapter) and the test `FakeSecureStorage` are both adapters at the same seam. Two adapters → real seam (per the principle below).

**Leverage**
What callers get from depth. More capability per unit of interface they have to learn. One implementation pays back across N call sites and M tests.

Example: BATCH-19a `ReaderSettings.==` / `hashCode` covers 31 fields with one `Object.hashAll([...])` impl. 40 unit tests + every `ref.listen` short-circuit in `reader_page.dart` benefit. That's leverage.

**Locality**
What maintainers get from depth. Change, bugs, knowledge, and verification concentrate at one place rather than spreading across callers. Fix once, fixed everywhere.

Example: `_paragraphKeyId(int chapterIndex, int paragraphIndex) => '$chapterIndex|$paragraphIndex'` is a tiny helper, but it concentrates the keyId format. BATCH-19b GlobalKey reverse lookup reused it instead of hand-writing `'${ch.index}_$idx'` (note the underscore vs pipe — would have silently mismatched). One fn = one place to keep formats in sync.

## Principles

- **Depth is a property of the interface, not the implementation.** A deep module can be internally composed of small, mockable, swappable parts — they just aren't part of the interface. A module can have **internal seams** (private to its implementation, used by its own tests) as well as the **external seam** at its interface.
- **The deletion test.** Imagine deleting the module. If complexity vanishes, the module wasn't hiding anything (it was a pass-through). If complexity reappears across N callers, the module was earning its keep.
- **The interface is the test surface.** Callers and tests cross the same seam. If you want to test *past* the interface, the module is probably the wrong shape.
- **One adapter means a hypothetical seam. Two adapters means a real one.** Don't introduce a seam unless something actually varies across it. (Counter-example caveat: in this repo, `setSecureStorageOverrideForTest` started with one adapter + one test fake — the test fake counts as a real second adapter, not just a mock-bucket.)

## Relationships

- A **Module** has exactly one **Interface** (the surface it presents to callers and tests).
- **Depth** is a property of a **Module**, measured against its **Interface**.
- A **Seam** is where a **Module**'s **Interface** lives.
- An **Adapter** sits at a **Seam** and satisfies the **Interface**.
- **Depth** produces **Leverage** for callers and **Locality** for maintainers.

## Rejected framings

- **Depth as ratio of implementation-lines to interface-lines** (Ousterhout): rewards padding the implementation. We use depth-as-leverage instead.
- **"Interface" as the TypeScript `interface` keyword or a class's public methods**: too narrow — interface here includes every fact a caller must know.
- **"Boundary"**: overloaded with DDD's bounded context. Say **seam** or **interface**.
