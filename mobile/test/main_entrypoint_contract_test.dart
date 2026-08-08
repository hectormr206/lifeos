// `main`'s argument list must stay OPTIONAL, or Android cannot start the app.
//
// This is a source contract rather than a behavioural test because the crash
// happens in the ENGINE, before any Dart this suite could drive: the entrypoint
// is invoked by the embedder, and no widget test can reproduce that call.
//
// What happened. Adding Linux login-autostart needed the `--hidden` flag, so
// `main()` became `main(List<String> arguments)`. On desktop GTK passes the
// real argv and it works. On Android, `FlutterFragmentActivity.getDartEntrypointArgs()`
// returns `getIntent().getSerializableExtra(EXTRA_DART_ENTRYPOINT_ARGS)` — an
// extra that a normal launcher start never sets — so it hands the engine null
// and `main` is invoked with NO arguments. A required positional parameter
// cannot be invoked that way, and the app closed itself the moment the user
// opened it.
//
// Every desktop build worked. Every one of the 2000+ tests passed. It reached
// the user's phone. The rule it broke is the standing one: if a change is not
// genuinely platform-specific, it has to hold on every platform — and a
// desktop-only need must not alter a signature every platform shares.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main accepts being called with no arguments at all', () {
    final source = File('lib/main.dart').readAsStringSync();

    // Optional-positional (`[List<String> x = const []]`) or fully absent are
    // the only forms Android can invoke. A bare required `List<String>` is not.
    final signature = RegExp(r'Future<void>\s+main\s*\(([^)]*)\)').firstMatch(source);
    expect(signature, isNotNull, reason: 'could not find main() in lib/main.dart');

    final params = signature!.group(1)!.trim();
    if (params.isEmpty) return; // main() — always invocable.

    expect(
      params.startsWith('['),
      isTrue,
      reason: 'main($params) is a REQUIRED parameter. Android invokes the '
          'entrypoint with no arguments, so the app will not start. Use '
          '[List<String> arguments = const []].',
    );
    expect(
      params.contains('='),
      isTrue,
      reason: 'the optional parameter has no default, so reading it when '
          'Android omits it throws',
    );
  });

  test('the contract can still fail — it is not matching a stale pattern', () {
    // A regex that quietly stopped matching would report a clean file forever,
    // which is how the original defect survived a full green suite.
    const broken = 'Future<void> main(List<String> arguments) async {';

    final signature = RegExp(r'Future<void>\s+main\s*\(([^)]*)\)').firstMatch(broken);

    expect(signature, isNotNull);
    expect(signature!.group(1)!.trim().startsWith('['), isFalse);
  });
}
