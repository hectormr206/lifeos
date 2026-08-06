import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/tray/tray_notice.dart';
import 'package:lifeos/core/tray/tray_providers.dart';
import 'package:lifeos/core/tray/tray_status.dart';
import 'package:lifeos/features/security/presentation/app_lock_providers.dart';

class _FixedTrayStatus extends TrayStatusNotifier {
  _FixedTrayStatus(this.fixed);

  final TrayStatus fixed;

  @override
  TrayStatus build() => fixed;
}

/// How the tray is attached to the running app.
///
/// Two things are asserted, and the second matters more than the first:
///
///   * `TrayNotice` really wraps the whole app, so a tray failure is visible
///     from any screen rather than only from wherever it happened; and
///   * pumping `LifeOSApp` in a test does NOT install a system tray icon on
///     the machine running the tests. The suite runs on a real Linux host, so
///     without that guard this file's siblings — all ~1 700 of them — would be
///     poking a live desktop session.
void main() {
  testWidgets('the tray notice wraps the whole app', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        overrides: [],
        child: LifeOSApp(),
      ),
    );
    await tester.pump();

    expect(find.byType(TrayNotice), findsOneWidget);
  });

  testWidgets('the notice lays out in its real position, above the router',
      (tester) async {
    // The notice test pumps it inside a Scaffold; here it sits where it
    // actually lives — in `MaterialApp.router`'s builder, wrapping the whole
    // Router subtree. A Column/Expanded in that position is exactly where an
    // unbounded-height overflow would show up, and it would only ever be seen
    // by a user whose tray had already failed.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The lock gate is OUTERMOST and puts everything under it Offstage
          // while locked, notice included. Unlocked here so the notice's real
          // layout is the thing under test.
          appLockInitialEnabledProvider.overrideWithValue(false),
          trayStatusProvider.overrideWith(
            () => _FixedTrayStatus(
              TrayUnavailable(
                reason: 'no StatusNotifierHost',
                error: StateError('x'),
                stackTrace: StackTrace.empty,
              ),
            ),
          ),
        ],
        child: const LifeOSApp(),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // Asserted by icon, not by text: LifeOSApp resolves its own locale from
    // the platform, which is en_US under the test harness.
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('pumping the app never starts a real tray under flutter test',
      (tester) async {
    final container = ProviderContainer(
      overrides: [appLockInitialEnabledProvider.overrideWithValue(false)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const LifeOSApp(),
      ),
    );
    // Let every post-frame callback (including the tray's) run.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Still untouched: no install was attempted, so there is neither a real
    // icon on the host nor a spurious "tray unavailable" notice.
    expect(container.read(trayStatusProvider), isA<TrayPending>());
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });
}
