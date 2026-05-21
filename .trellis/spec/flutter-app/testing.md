# Testing

The Flutter app ships ~421 tests covering widgets, helpers, and a handful of integration-style flows. Tests live in `flutter_app/test/`, parallel to the feature they cover.

## Conventions

- One test file per page or helper. Filename is `<thing>_test.dart` matching the source file's name.
- Tests are written with `flutter_test`'s `testWidgets` and `test`. No `flutter_test_robots` or third-party harness.
- Every test must run without network, real `path_provider`, or real FRB. Use `*Override` test hooks (see below) and `tempfile`-style temp directories.

## Test Hook Pattern

Pages expose optional override constructors so tests can inject fakes. The pattern in `features/rule_sub/rule_sub_page.dart`:

```dart
class RuleSubPage extends ConsumerStatefulWidget {
  final String? dbPathOverride;
  final Future<int> Function(String, String)? deleteOverride;
  final Future<int> Function(String, String, String, String, int)? updateOverride;

  const RuleSubPage({super.key, this.dbPathOverride, this.deleteOverride, this.updateOverride});
}
```

Inside the State, the override is resolved at call time:

```dart
final fn = widget.deleteOverride ??
    (String db, String i) async {
      final n = await rust_api.ruleSubDelete(dbPath: db, id: i);
      return platformInt64ToInt(n);
    };
```

Rules:

- Production code path is the default (no `Override` set). The override is read once per call.
- Override types match the production FRB signature. Use `String` / `int` / `bool` for primitives.
- Always combine `dbPathOverride` with at least one FRB override. A test that fakes the FRB call but uses real `dbPath` still touches `path_provider`.

## ProviderScope.overrides (preferred for new code)

For new pages and refactors, prefer the `ProviderScope.overrides` pattern over `*Override` constructor params. See [state-and-providers.md::API Client Service Providers](./state-and-providers.md) for the rationale.

Test pattern (canonical example: `test/backup_page_test.dart` post-BATCH-20):

```dart
testWidgets('BackupPage validate after pick + confirm', (tester) async {
  int validateCalls = 0;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backupApiClientProvider.overrideWithValue(
          _FakeBackupApiClient(
            onValidate: (zip) async {
              validateCalls++;
              return ['bookshelf.json', 'bookGroup.json'];
            },
          ),
        ),
        filePickerServiceProvider.overrideWithValue(
          _FakeFilePickerService(onPickZipFile: () async => '/tmp/test.zip'),
        ),
      ],
      child: const MaterialApp(
        home: BackupPage(dbPathOverride: '/tmp/legado-test.db'),
      ),
    ),
  );
  // ... assertions
});

class _FakeBackupApiClient extends BackupApiClient {
  final Future<List<String>> Function(String)? onValidate;
  // ... other optional callbacks
  const _FakeBackupApiClient({this.onValidate, ...}) : super();

  @override
  Future<List<String>> validateZip({required String zipPath}) {
    final fn = onValidate;
    if (fn == null) throw UnimplementedError('onValidate not configured');
    return fn(zipPath);
  }
  // ... only override methods the test exercises
}
```

Rules for fakes:

- `extends`, not `implements` — production behavior inherited for un-overridden methods.
- Optional callback fields per method — lets tests configure precisely the methods they exercise; un-configured methods throw `UnimplementedError` to surface accidental real calls.
- `const` constructor when callbacks are nullable.
- Place fakes at the top of the test file unless 2+ tests share the same fake (then move to `test/_helpers/fakes.dart`).
- Fakes are package-private (`_FakeXxx` underscore prefix) unless shared across files.

When still to use `*Override` constructor (legacy pattern):

- Single cross-cutting injection that doesn't fit a service abstraction. `dbPathOverride` for path_provider bypass is the canonical surviving example (preserved by BATCH-20).
- Existing pages with established `*Override` test surface — don't migrate just for consistency; migrate when refactoring the page anyway.

## Helper Tests

Pure helpers in `core/util/` get plain `test(...)` blocks (no widget tree):

```dart
test('platformInt64ToInt: int 直接返回原值', () {
  expect(platformInt64ToInt(42), 42);
});

test('formatRelativeTime: sec=0 返回 "从未"', () {
  expect(formatRelativeTime(0), '从未');
});
```

Each helper file in `core/util/` has a matching `<helper>_test.dart` covering at least 3 cases (happy path + at least one edge case + at least one error case).

## Persistence Tests

Pass `directory: tempDir` to bypass path_provider:

```dart
test('writeJsonKey + readJsonKey round-trips', () async {
  final tmp = await Directory.systemTemp.createTemp();
  await writeJsonKey('foo', 42, directory: tmp);
  final v = await readJsonKey<int>('foo', (r) => r as int, 0, directory: tmp);
  expect(v, 42);
});
```

`json_store_test.dart` is the canonical reference for these patterns.

## Widget Tests Touching `mounted`

The `safe_setstate_test.dart` shows how to test `mounted=false` paths:

```dart
testWidgets('safeSetState is no-op when unmounted', (tester) async {
  await tester.pumpWidget(const MaterialApp(home: _CounterPage()));
  final state = tester.state<_CounterPageState>(find.byType(_CounterPage));
  // Replace the widget tree to dispose the State.
  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  expect(state.mounted, isFalse);
  expect(() => state.safeSetState(() {}), returnsNormally);
});
```

The trick: hold a reference to the State before disposing the widget tree, then assert behavior on the unmounted instance.

## Anti-Patterns

- **Mocking `rust_api` globally.** This breaks when test files run in parallel. Use page-level overrides instead.
- **Real `Future.delayed` in tests.** `tester.pump(Duration(seconds: 1))` advances the fake async clock without sleeping.
- **Tests that depend on font metrics or device pixels.** Pin `tester.binding.setDevicePixelRatio(1.0)` if needed and use `find.text` rather than golden images.
- **Skipping invalidation tests.** Whenever a feature mutates and invalidates providers, write a test that asserts the dependent providers re-fetch. The reader / source / settings tests have several examples.

## Running

```bash
cd flutter_app
flutter test                                    # whole suite
flutter test test/safe_setstate_test.dart       # one file
flutter test --plain-name 'safeSetState'        # filter by name substring
flutter test --reporter expanded                # see each test name
```

`flutter analyze` is a hard prerequisite; tests will not catch lint regressions.
