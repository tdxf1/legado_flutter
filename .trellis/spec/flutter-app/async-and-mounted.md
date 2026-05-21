# Async and `mounted`

Flutter `setState` after `await` is the most common UI bug source in this app. The repository uses two complementary patterns.

## Pattern 1: Early-Return `if (!mounted) return;`

For multi-line work that does several things after an `await`:

```dart
Future<void> _onSave() async {
  setState(() => _saving = true);
  try {
    await rust_api.saveBook(dbPath: dbPath, bookJson: jsonEncode(book));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('保存成功')),
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  } finally {
    safeSetState(() => _saving = false);
  }
}
```

Rules:

- One `if (!mounted) return;` immediately after each `await` whose continuation touches `context`, `ref`, or calls `setState`.
- This is the **dominant** pattern in the codebase (132 occurrences as of BATCH-25 audit).
- Do not collapse multiple post-await statements into a single `safeSetState` if any of them are `Navigator.pop` / `ScaffoldMessenger` / `showDialog`. Those are not `setState`.

## Pattern 2: `safeSetState(() => ...)`

For the single-line "I just want to flip a flag after await":

```dart
final result = await rust_api.fetchSomething();
safeSetState(() => _data = result);
```

`safeSetState` is defined in `core/widgets/safe_setstate.dart`:

```dart
extension SafeSetState<T extends StatefulWidget> on State<T> {
  void safeSetState(VoidCallback fn) {
    if (!mounted) return;
    // ignore: invalid_use_of_protected_member
    setState(fn);
  }
}
```

Rules:

- Use `safeSetState` whenever the original code was `if (mounted) setState(() => ...)`. BATCH-25 mechanically replaced 31 such sites.
- Do **not** use `safeSetState` to wrap multi-line bodies unless every line is a setState mutation. Keep `if (!mounted) return;` for early-return work.
- Do **not** use it instead of an early return when the work after `await` is non-`setState` (Navigator pop, SnackBar, showDialog).

## When to Use `context.mounted` Instead

`context.mounted` (Flutter SDK) is for `BuildContext` parameters captured inside dialog / popup builders, where the page-level `State.mounted` is not in scope. Examples in `features/bookshelf/bookshelf_page.dart`:

```dart
PopupMenuButton(
  onSelected: (value) async {
    await Navigator.push(context, ...);
    if (!context.mounted) return;
    context.push('/some-route');
  },
)
```

Do not convert these to `mounted`. The semantics differ — `context.mounted` checks the dialog/route's element, not the page's state.

## Real Bug Caught by This Style

`features/reader/reader_page.dart::_replaceBookSource` had two consecutive `await`s before `setState({...})` without a `mounted` check. Closing the change-source dialog and immediately popping the reader could trigger `setState() called after dispose`. Fixed in BATCH-25 by adding `if (!mounted) return;` between the second `await` and the `setState`. This kind of audit is described in [code-reuse-thinking-guide](../guides/code-reuse-thinking-guide.md) and the cross-layer guide.

## Verification

Quick grep:

```bash
cd flutter_app/lib/features
grep -rn 'if (mounted) setState' .   # should print 0 matches
grep -rn 'safeSetState'              # should print >=31 matches
```

If new code reintroduces `if (mounted) setState`, prefer the `safeSetState` extension. If you must write the long form (e.g. needing both setState and a non-setState side effect), use the early-return pattern instead.
