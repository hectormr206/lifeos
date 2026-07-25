// Proves the app-lock GATE hides app content behind the lock screen until a
// biometric auth succeeds, that a failed attempt keeps it locked and lets the
// user retry with the "Desbloquear" button, and that a disabled lock is a
// transparent pass-through.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/security/domain/biometric_authenticator.dart';
import 'package:lifeos/features/security/presentation/app_lock_gate.dart';
import 'package:lifeos/features/security/presentation/app_lock_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../support/fakes.dart';

Widget _app({
  required bool initialEnabled,
  required FakeBiometricAuthenticator auth,
}) =>
    ProviderScope(
      overrides: [
        appLockInitialEnabledProvider.overrideWithValue(initialEnabled),
        biometricAuthenticatorProvider.overrideWithValue(auth),
        appLockPreferencesProvider.overrideWithValue(FakeAppLockPreferences(
          enabled: initialEnabled,
        )),
      ],
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AppLockGate(child: Text('CONTENT')),
      ),
    );

void main() {
  testWidgets('disabled lock shows content directly (no gate)', (tester) async {
    await tester.pumpWidget(_app(
      initialEnabled: false,
      auth: FakeBiometricAuthenticator(),
    ));
    await tester.pump();

    expect(find.text('CONTENT'), findsOneWidget);
    expect(find.text('LifeOS está bloqueado'), findsNothing);
  });

  testWidgets('content stays hidden until auth succeeds', (tester) async {
    final gate = Completer<void>();
    final auth = FakeBiometricAuthenticator(
      result: BiometricAuthResult.success,
      gate: gate,
    );
    await tester.pumpWidget(_app(initialEnabled: true, auth: auth));
    // Let the auto-prompt fire (postFrame) — it is now pending on the gate.
    await tester.pump();

    // Locked: the lock screen is up, app content is NOT revealed.
    expect(find.text('CONTENT'), findsNothing);
    expect(find.text('LifeOS está bloqueado'), findsOneWidget);

    // Auth resolves successfully → content appears.
    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('CONTENT'), findsOneWidget);
    expect(find.text('LifeOS está bloqueado'), findsNothing);
    expect(auth.calls, 1);
  });

  testWidgets('a failed attempt keeps it locked; "Desbloquear" retries',
      (tester) async {
    final auth = FakeBiometricAuthenticator(result: BiometricAuthResult.failed);
    await tester.pumpWidget(_app(initialEnabled: true, auth: auth));
    await tester.pumpAndSettle();

    // Auto-prompt failed → still locked, content hidden.
    expect(find.text('CONTENT'), findsNothing);
    expect(find.text('Desbloquear'), findsOneWidget);
    expect(auth.calls, 1);

    // The user fixes it (or retries) and taps Desbloquear → success this time.
    auth.result = BiometricAuthResult.success;
    await tester.tap(find.text('Desbloquear'));
    await tester.pumpAndSettle();

    expect(find.text('CONTENT'), findsOneWidget);
    expect(auth.calls, 2);
  });

  testWidgets(
      're-lock keeps the child MOUNTED underneath (state survives, '
      'content hidden)', (tester) async {
    // Regression: the gate used to return LockScreen INSTEAD of the child,
    // unmounting the whole Router on re-lock and losing navigation +
    // in-progress state (chat drafts, scroll positions, recordings).
    final auth = FakeBiometricAuthenticator(result: BiometricAuthResult.success);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appLockInitialEnabledProvider.overrideWithValue(true),
        biometricAuthenticatorProvider.overrideWithValue(auth),
        appLockPreferencesProvider
            .overrideWithValue(FakeAppLockPreferences(enabled: true)),
      ],
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AppLockGate(child: _StatefulProbe()),
      ),
    ));
    await tester.pumpAndSettle(); // auto-prompt succeeds → unlocked.
    expect(find.text('draft: hola'), findsOneWidget);

    // Re-lock (app backgrounded). The probe's State must SURVIVE.
    final element = tester.element(find.byType(AppLockGate));
    final container = ProviderScope.containerOf(element, listen: false);
    container.read(appLockControllerProvider.notifier).onBackground();
    await tester.pump();

    // Locked: content is hidden (offstage) and not hit-testable…
    expect(find.text('draft: hola'), findsNothing);
    expect(find.text('LifeOS está bloqueado'), findsOneWidget);
    // …but the State is still alive underneath.
    expect(_StatefulProbeState.disposeCount, 0,
        reason: 're-lock must never dispose the app subtree');

    // Unlock again → the exact same state (the draft) is restored.
    await tester.tap(find.text('Desbloquear'));
    await tester.pumpAndSettle();
    expect(find.text('draft: hola'), findsOneWidget);
    expect(_StatefulProbeState.disposeCount, 0);
  });

  testWidgets('an unavailable device offers a disable escape (no hard brick)',
      (tester) async {
    final auth =
        FakeBiometricAuthenticator(result: BiometricAuthResult.unavailable);
    await tester.pumpWidget(_app(initialEnabled: true, auth: auth));
    await tester.pumpAndSettle();

    // Explains the situation and offers "Desactivar bloqueo".
    expect(find.text('Desactivar bloqueo'), findsOneWidget);
    expect(find.text('CONTENT'), findsNothing);

    await tester.tap(find.text('Desactivar bloqueo'));
    await tester.pumpAndSettle();

    // Lock disabled → content revealed.
    expect(find.text('CONTENT'), findsOneWidget);
  });
}

/// A child holding mutable State — stands in for the Router subtree (chat
/// composer draft, scroll positions). [disposeCount] proves survival.
class _StatefulProbe extends StatefulWidget {
  const _StatefulProbe();

  @override
  State<_StatefulProbe> createState() => _StatefulProbeState();
}

class _StatefulProbeState extends State<_StatefulProbe> {
  static int disposeCount = 0;
  final String draft = 'hola';

  @override
  void dispose() {
    disposeCount++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text('draft: $draft');
}
