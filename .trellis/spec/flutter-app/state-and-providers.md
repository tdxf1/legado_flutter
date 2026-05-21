# State and Providers

Riverpod 2 is the only state-management library used in this app. There are no `ChangeNotifier`s, no `Bloc`s, and no global singletons (besides the FRB binding).

## Provider Shapes Used

| Shape | When | Example |
|---|---|---|
| `Provider<T>` | Pure derived value, no IO. | `lightThemeProvider` in `core/providers.dart` |
| `StateProvider<T>` | Mutable in-memory state, no persistence. | `themeModeProvider` |
| `FutureProvider<T>` | One-shot async load (DB path, initial data). | `dbDirProvider` (calls `resolvePersistenceDir`) |
| `FutureProvider.family<T, P>` | Async by parameter (book id, source id). | `bookByIdProvider`, `bookChaptersProvider` |
| `StreamProvider<T>` | Used sparingly. Only when the underlying source is a real `Stream`. | none in current codebase |
| `NotifierProvider` / `AsyncNotifierProvider` | Not used yet — the codebase predates them. New code may adopt them when state needs methods. | — |

For new state, prefer the simplest shape that fits. Most features today use `ConsumerStatefulWidget` with `setState` for local UI state and `ref.read(...)` to call into providers, rather than building a `Notifier` per page.

## Settings IO Wrappers

`core/providers.dart` contains 17 paired functions of the form:

```dart
Future<double> loadFontSizeFromDisk();
Future<void> saveFontSizeToDisk(double v);
Future<void> clearFontSizeFromDisk();   // some keys only
```

Every wrapper delegates to `core/persistence/json_store.dart`:

```dart
Future<double> loadFontSizeFromDisk() async {
  return readJsonKey<double>(
    'fontSize',
    (raw) => raw is num ? raw.toDouble().clamp(14.0, 28.0) : 18.0,
    18.0,
  );
}

Future<void> saveFontSizeToDisk(double v) async {
  await writeJsonKey('fontSize', v, errorTag: 'font size');
}
```

Rules for adding a new settings key:

1. Add load/save (and optionally clear) wrappers to `providers.dart`.
2. Pass the parser as a closure that **never throws** — fall back to a default on shape mismatch. `json_store` will fall back to default on parse exception, but explicit defaults read better in the diff.
3. Bound numeric values with `.clamp(...)` so corrupt user files never produce out-of-range values.
4. Use `errorTag` so write failures show useful debugPrint output.
5. Add at least one widget-test exercising the load path with a custom `directory:` to bypass `path_provider`.

The full list of keys is documented in `core/persistence/json_store.dart` doc-comment. Do not introduce a parallel persistence file for one-off keys; the `settings.json` shared object is intentional (BATCH-18c rationalized 17 ad-hoc files into one).

## Derived State (Single Source of Truth)

`fontSizeProvider` is **not** a `StateProvider`; it is a derived `Provider` reading from `readerSettingsProvider`:

```dart
final fontSizeProvider = Provider<double>((ref) {
  final settings = ref.watch(readerSettingsProvider);
  return settings.fontSize;
});
```

Why: before BATCH-18d the same value lived in two providers. Editing one didn't update the other. The fix made `readerSettings` the source of truth and `fontSizeProvider` a thin lens.

When introducing a new piece of UI state that overlaps with an existing provider, **derive** rather than duplicate. Two writers to the same conceptual value is a recurring bug pattern (`findings-flutter-core.md::F-W2A-008`).

## Invalidation Patterns

After mutating data through a `bridge::api::*` call, invalidate the affected providers:

```dart
await rust_api.deleteBook(dbPath: dbPath, id: bookId);
ref.invalidate(allBooksProvider);
ref.invalidate(booksByGroupProvider);
ref.invalidate(bookChaptersProvider(bookId));
```

Rules:

- Always invalidate **after** the FRB call returns (await first).
- Invalidate every provider whose result depends on the mutated row, not just the most obvious one. Backups touch 5 invalidations (allBooks / booksByGroup / bookGroups / allSources / allReplaceRules) — see `features/settings/backup_page.dart` for the reference list.
- Family providers must be invalidated by exact parameter when known, otherwise by whole family. Prefer parameter-precise invalidation.

## Read vs Watch

- Inside `build` → `ref.watch(...)`. Rebuild on change.
- Inside event handlers / async callbacks → `ref.read(...)`. One-shot read.
- `ref.refresh(...)` is rare; only use when you need the new value synchronously.

The codebase has no `ref.listen` callers today. If you add one, document why in a comment.
