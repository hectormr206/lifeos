// Proves the Settings hub biometric-app-lock toggle: turning it ON requires a
// successful confirm auth (a failed confirm does NOT enable it and surfaces a
// message), and turning it OFF disables it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/security/domain/biometric_authenticator.dart';
import 'package:lifeos/features/security/presentation/app_lock_controller.dart';
import 'package:lifeos/features/security/presentation/app_lock_providers.dart';
import 'package:lifeos/features/settings/presentation/settings_hub_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/locale_providers.dart';
import 'package:lifeos/theme/theme_providers.dart';

import '../../../support/fake_language_preferences.dart';
import '../../../support/fake_theme_mode_preferences.dart';
import '../../app_update/support/fakes.dart';
import '../../security/support/fakes.dart';

Widget _app({
  required bool initialEnabled,
  required FakeBiometricAuthenticator auth,
  required FakeAppLockPreferences prefs,
}) =>
    ProviderScope(
      overrides: [
        themeModePreferencesProvider.overrideWithValue(FakeThemeModePreferences()),
        languagePreferencesProvider.overrideWithValue(FakeLanguagePreferences()),
        appVersionInfoProvider
            .overrideWithValue(FakeAppVersionInfo(code: 10, name: '1.0.0')),
        appLockInitialEnabledProvider.overrideWithValue(initialEnabled),
        biometricAuthenticatorProvider.overrideWithValue(auth),
        appLockPreferencesProvider.overrideWithValue(prefs),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/settings',
          routes: [
            GoRoute(path: '/settings', builder: (c, s) => const SettingsHubScreen()),
          ],
        ),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );

void main() {
  // The hub is a long scrolling list; give tests a tall viewport so the
  // Security section is laid out (a ListView only builds visible children).
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.physicalSize = const Size(1000, 3600);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('renders the Security section + toggle', (tester) async {
    await tester.pumpWidget(_app(
      initialEnabled: false,
      auth: FakeBiometricAuthenticator(),
      prefs: FakeAppLockPreferences(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Seguridad'), findsOneWidget);
    expect(find.text('Bloqueo con huella o rostro'), findsOneWidget);
  });

  testWidgets('turning ON requires a successful confirm auth', (tester) async {
    final auth = FakeBiometricAuthenticator(result: BiometricAuthResult.success);
    final prefs = FakeAppLockPreferences();
    await tester.pumpWidget(_app(initialEnabled: false, auth: auth, prefs: prefs));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.text('Seguridad')));
    expect(container.read(appLockControllerProvider), AppLockStatus.disabled);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(auth.calls, 1);
    expect(prefs.writes, 1);
    expect(container.read(appLockEnabledProvider), isTrue);
  });

  testWidgets('a FAILED confirm does not enable it and shows a message',
      (tester) async {
    final auth = FakeBiometricAuthenticator(result: BiometricAuthResult.failed);
    final prefs = FakeAppLockPreferences();
    await tester.pumpWidget(_app(initialEnabled: false, auth: auth, prefs: prefs));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.text('Seguridad')));

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(auth.calls, 1);
    expect(prefs.writes, 0);
    expect(container.read(appLockEnabledProvider), isFalse);
    expect(find.text('No se pudo verificar. El bloqueo sigue desactivado.'),
        findsOneWidget);
  });

  testWidgets('turning OFF disables the lock', (tester) async {
    final auth = FakeBiometricAuthenticator();
    final prefs = FakeAppLockPreferences(enabled: true);
    await tester.pumpWidget(_app(initialEnabled: true, auth: auth, prefs: prefs));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.text('Seguridad')));
    expect(container.read(appLockEnabledProvider), isTrue);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    // Disabling never prompts.
    expect(auth.calls, 0);
    expect(prefs.writes, 1);
    expect(container.read(appLockEnabledProvider), isFalse);
  });
}
