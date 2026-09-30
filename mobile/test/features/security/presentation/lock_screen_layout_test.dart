import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/security/domain/biometric_authenticator.dart';
import 'package:lifeos/features/security/presentation/app_lock_providers.dart';
import 'package:lifeos/features/security/presentation/lock_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/theme/lifeos_theme.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('the lock screen shows the Axi mark under a headline title',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appLockInitialEnabledProvider.overrideWithValue(true),
        biometricAuthenticatorProvider.overrideWithValue(
          FakeBiometricAuthenticator(result: BiometricAuthResult.failed),
        ),
        appLockPreferencesProvider
            .overrideWithValue(FakeAppLockPreferences(enabled: true)),
      ],
      child: MaterialApp(
        theme: lifeosLightTheme,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LockScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    final mark = find.byKey(const Key('lock-axi-mark'));
    expect(mark, findsOneWidget);
    expect(tester.getSize(mark).width, 96);
    expect(find.byIcon(Icons.fingerprint), findsOneWidget);

    final title = tester.widget<Text>(find.text('LifeOS está bloqueado'));
    expect(title.style?.fontSize, lifeosLightTheme.textTheme.headlineMedium?.fontSize);
  });
}
