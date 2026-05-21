# Flutter App

Coding guidance for `flutter_app/`. The Flutter app is a single Dart package that consumes the Rust `bridge` crate via flutter_rust_bridge. The codebase uses Riverpod 2 for state, go_router 14 for navigation, and a hand-rolled feature folder layout.

## Layout Overview

```
flutter_app/
├── android/                   Android Gradle wrapper, manifest, keystore wiring
├── lib/
│   ├── main.dart              ProviderScope + MaterialApp.router boot
│   ├── src/rust/              flutter_rust_bridge auto-generated bindings — never edit
│   ├── core/                  Cross-feature primitives (see below)
│   └── features/              10 feature packages, one folder each
├── test/                      ~421 widget + unit tests
└── pubspec.yaml               sdk >=3.3.0, flutter >=3.35
```

## `lib/core/` Layout

```
core/
├── providers.dart             ~30 Riverpod providers + 17 settings load/save wrappers
├── router.dart                go_router routes; one entry per feature page
├── theme.dart                 AppTheme.light / .dark
├── dto.dart                   Shared data transfer types (kept minimal)
├── notification_service.dart  flutter_local_notifications wiring
├── cover_cache.dart           Disk-cache layer for book cover URLs
├── download_runner.dart       Chapter pre-download orchestrator
├── perf_monitor.dart          Reader frame-time instrumentation
├── platform_webview_executor.dart  WebView JS bridge wrapper
├── refresh_rate_controller.dart    Display.setHighRefreshRate
├── persistence/
│   └── json_store.dart        readJsonKey / writeJsonKey / readJsonFile / writeJsonFile
├── util/
│   ├── platform_int64.dart    PlatformInt64 → int bridge helper
│   ├── time_format.dart       formatRelativeTime(int sec) helper
│   └── import_summary_label.dart  Import/restore SnackBar label helper
└── widgets/
    └── safe_setstate.dart     SafeSetState extension on State<T>
```

`core/` files may import from each other freely. They never import from `features/`.

## `lib/features/` Layout

```
features/
├── bookshelf/   Books grid + groups + import-local-book + per-book actions
├── reader/      Reader page (~2900 lines) + page_view + change_source_dialog + tts
├── search/      In-app search + history persistence + precision toggle
├── source/      Book-source management + rules editor
├── rss/         RSS source manage + article list + article detail + favorites
├── settings/    Backup / WebDAV / read-stats / cache-management / settings index
├── replace_rule/ Replace-rule list + edit dialog
├── rule_sub/    Rule subscription URL manager
├── qr/          mobile_scanner-based QR import
├── download/    Download queue page
```

Each feature folder owns its pages, dialogs, and per-feature widgets. Cross-feature widgets that two or more features need go in `core/widgets/`.

## Spec Index

| Topic | File |
|---|---|
| Folder boundaries and import rules | [directory-structure.md](./directory-structure.md) |
| Riverpod patterns + the 17 settings IO wrappers | [state-and-providers.md](./state-and-providers.md) |
| `mounted` style, `safeSetState`, async-after-await pitfalls | [async-and-mounted.md](./async-and-mounted.md) |
| Settings persistence and `json_store.dart` | [persistence.md](./persistence.md) |
| Test hooks (`*Override`), widget tests, fixture style | [testing.md](./testing.md) |
| Forbidden patterns and quality bar | [quality-and-anti-patterns.md](./quality-and-anti-patterns.md) |

## Quick Verification

```bash
cd flutter_app
flutter analyze         # 0 issue required
flutter test            # ~421 tests, all green
```

The current baseline is recorded in `.trellis/tasks/archive/2026-05/05-21-batch-25-mounted-style-safesetstate/prd.md`.
