// Proves the AppLockController state machine: initial state from the pre-frame
// flag, authenticate() success/failure, re-lock on background, the re-prompt
// loop guard, and enable()/disable() (enabling REQUIRES a successful confirm).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/security/domain/biometric_authenticator.dart';
import 'package:lifeos/features/security/presentation/app_lock_controller.dart';
import 'package:lifeos/features/security/presentation/app_lock_providers.dart';

import '../support/fakes.dart';

ProviderContainer _container({
  required bool initialEnabled,
  required FakeBiometricAuthenticator auth,
  required FakeAppLockPreferences prefs,
  FakeSecureScreenGateway? secure,
}) {
  final container = ProviderContainer(
    overrides: [
      appLockInitialEnabledProvider.overrideWithValue(initialEnabled),
      biometricAuthenticatorProvider.overrideWithValue(auth),
      appLockPreferencesProvider.overrideWithValue(prefs),
      if (secure != null) secureScreenGatewayProvider.overrideWithValue(secure),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('initial state', () {
    test('disabled when the pre-frame flag is off', () {
      final container = _container(
        initialEnabled: false,
        auth: FakeBiometricAuthenticator(),
        prefs: FakeAppLockPreferences(),
      );
      expect(container.read(appLockControllerProvider), AppLockStatus.disabled);
    });

    test('locked when the pre-frame flag is on', () {
      final container = _container(
        initialEnabled: true,
        auth: FakeBiometricAuthenticator(),
        prefs: FakeAppLockPreferences(enabled: true),
      );
      expect(container.read(appLockControllerProvider), AppLockStatus.locked);
    });
  });

  group('authenticate', () {
    test('success unlocks and passes the neutral-Spanish reason', () async {
      final auth = FakeBiometricAuthenticator(result: BiometricAuthResult.success);
      final container = _container(
        initialEnabled: true,
        auth: auth,
        prefs: FakeAppLockPreferences(enabled: true),
      );
      final notifier = container.read(appLockControllerProvider.notifier);

      final result = await notifier.authenticate();

      expect(result, BiometricAuthResult.success);
      expect(container.read(appLockControllerProvider), AppLockStatus.unlocked);
      expect(auth.reasons.single, kAppLockReason);
    });

    test('failure keeps it locked so the user can retry', () async {
      final auth = FakeBiometricAuthenticator(result: BiometricAuthResult.failed);
      final container = _container(
        initialEnabled: true,
        auth: auth,
        prefs: FakeAppLockPreferences(enabled: true),
      );
      final notifier = container.read(appLockControllerProvider.notifier);

      final result = await notifier.authenticate();

      expect(result, BiometricAuthResult.failed);
      expect(container.read(appLockControllerProvider), AppLockStatus.locked);
    });
  });

  group('re-lock on background', () {
    test('re-locks when unlocked', () async {
      final container = _container(
        initialEnabled: true,
        auth: FakeBiometricAuthenticator(result: BiometricAuthResult.success),
        prefs: FakeAppLockPreferences(enabled: true),
      );
      final notifier = container.read(appLockControllerProvider.notifier);
      await notifier.authenticate();
      expect(container.read(appLockControllerProvider), AppLockStatus.unlocked);

      notifier.onBackground();

      expect(container.read(appLockControllerProvider), AppLockStatus.locked);
    });

    test('is a no-op when the lock is disabled', () {
      final container = _container(
        initialEnabled: false,
        auth: FakeBiometricAuthenticator(),
        prefs: FakeAppLockPreferences(),
      );
      final notifier = container.read(appLockControllerProvider.notifier);

      notifier.onBackground();

      expect(container.read(appLockControllerProvider), AppLockStatus.disabled);
    });

    test(
        'does NOT re-lock while a prompt is in flight — the prompt itself '
        'backgrounds the app, and re-locking there would loop', () async {
      final gate = Completer<void>();
      final auth = FakeBiometricAuthenticator(
        result: BiometricAuthResult.success,
        gate: gate,
      );
      final container = _container(
        initialEnabled: true,
        auth: auth,
        prefs: FakeAppLockPreferences(enabled: true),
      );
      final notifier = container.read(appLockControllerProvider.notifier);

      // First auth (immediate) → unlocked.
      final firstGate = gate;
      // Start a gated attempt while already unlocked to reach the exact race:
      // status == unlocked AND an attempt in flight. First, unlock via a
      // separate immediate success.
      auth.gate = null;
      await notifier.authenticate();
      expect(container.read(appLockControllerProvider), AppLockStatus.unlocked);

      // Now arm the gate and start a new attempt that stays pending.
      auth.gate = firstGate;
      final pending = notifier.authenticate();

      // The OS dialog backgrounds the app mid-prompt → onBackground fires.
      notifier.onBackground();

      // Guarded: still unlocked, NOT re-locked (which would re-mount the lock
      // screen and re-prompt forever).
      expect(container.read(appLockControllerProvider), AppLockStatus.unlocked);

      firstGate.complete();
      await pending;
      expect(container.read(appLockControllerProvider), AppLockStatus.unlocked);
      // No stacked prompts: exactly the two deliberate attempts.
      expect(auth.calls, 2);
    });
  });

  group('enable', () {
    test('requires a successful confirm: enables + persists on success', () async {
      final auth = FakeBiometricAuthenticator(result: BiometricAuthResult.success);
      final prefs = FakeAppLockPreferences();
      final container = _container(initialEnabled: false, auth: auth, prefs: prefs);
      final notifier = container.read(appLockControllerProvider.notifier);

      final result = await notifier.enable();

      expect(result, BiometricAuthResult.success);
      expect(prefs.writes, 1);
      expect(await prefs.isEnabled(), isTrue);
      // Armed + already satisfied for this session.
      expect(container.read(appLockControllerProvider), AppLockStatus.unlocked);
    });

    test('a FAILED confirm does NOT enable or persist', () async {
      final auth = FakeBiometricAuthenticator(result: BiometricAuthResult.failed);
      final prefs = FakeAppLockPreferences();
      final container = _container(initialEnabled: false, auth: auth, prefs: prefs);
      final notifier = container.read(appLockControllerProvider.notifier);

      final result = await notifier.enable();

      expect(result, BiometricAuthResult.failed);
      expect(prefs.writes, 0);
      expect(await prefs.isEnabled(), isFalse);
      expect(container.read(appLockControllerProvider), AppLockStatus.disabled);
    });

    test('an UNAVAILABLE device does NOT enable or persist', () async {
      final auth =
          FakeBiometricAuthenticator(result: BiometricAuthResult.unavailable);
      final prefs = FakeAppLockPreferences();
      final container = _container(initialEnabled: false, auth: auth, prefs: prefs);
      final notifier = container.read(appLockControllerProvider.notifier);

      final result = await notifier.enable();

      expect(result, BiometricAuthResult.unavailable);
      expect(prefs.writes, 0);
      expect(container.read(appLockControllerProvider), AppLockStatus.disabled);
    });
  });

  group('native secure surface (FLAG_SECURE follows the toggle)', () {
    test('armed on build when the lock is enabled', () async {
      final secure = FakeSecureScreenGateway();
      final container = _container(
        initialEnabled: true,
        auth: FakeBiometricAuthenticator(),
        prefs: FakeAppLockPreferences(enabled: true),
        secure: secure,
      );
      container.read(appLockControllerProvider);
      await pumpEventQueue();

      expect(secure.current, isTrue,
          reason: 'the Recents snapshot must be protected while armed');
    });

    test('released on build when the lock is disabled (screenshots work)',
        () async {
      final secure = FakeSecureScreenGateway();
      final container = _container(
        initialEnabled: false,
        auth: FakeBiometricAuthenticator(),
        prefs: FakeAppLockPreferences(),
        secure: secure,
      );
      container.read(appLockControllerProvider);
      await pumpEventQueue();

      expect(secure.current, isFalse);
    });

    test('enable() arms it; disable() releases it', () async {
      final secure = FakeSecureScreenGateway();
      final container = _container(
        initialEnabled: false,
        auth: FakeBiometricAuthenticator(result: BiometricAuthResult.success),
        prefs: FakeAppLockPreferences(),
        secure: secure,
      );
      final notifier = container.read(appLockControllerProvider.notifier);

      await notifier.enable();
      await pumpEventQueue();
      expect(secure.current, isTrue);

      await notifier.disable();
      await pumpEventQueue();
      expect(secure.current, isFalse);
    });

    test('a FAILED enable never arms the secure surface', () async {
      final secure = FakeSecureScreenGateway();
      final container = _container(
        initialEnabled: false,
        auth: FakeBiometricAuthenticator(result: BiometricAuthResult.failed),
        prefs: FakeAppLockPreferences(),
        secure: secure,
      );
      await container.read(appLockControllerProvider.notifier).enable();
      await pumpEventQueue();

      expect(secure.current, isFalse, reason: 'only the build-time release');
    });
  });

  test('disable persists off and reveals content', () async {
    final prefs = FakeAppLockPreferences(enabled: true);
    final container = _container(
      initialEnabled: true,
      auth: FakeBiometricAuthenticator(),
      prefs: prefs,
    );
    final notifier = container.read(appLockControllerProvider.notifier);

    await notifier.disable();

    expect(prefs.writes, 1);
    expect(await prefs.isEnabled(), isFalse);
    expect(container.read(appLockControllerProvider), AppLockStatus.disabled);
  });
}
