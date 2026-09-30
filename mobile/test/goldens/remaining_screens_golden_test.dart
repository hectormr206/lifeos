// Remaining reachable screens (first-run onboarding, lock, dictate, desahogo),
// pumped against fakes: no platform channel, no microphone, no biometrics.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/confession/presentation/confession_screen.dart';
import 'package:lifeos/features/dictation/presentation/dictate_screen.dart';
import 'package:lifeos/features/first_day/domain/first_day_copy.dart';
import 'package:lifeos/features/permissions/domain/app_permission.dart';
import 'package:lifeos/features/permissions/domain/onboarding_preferences.dart';
import 'package:lifeos/features/permissions/domain/permissions_gateway.dart';
import 'package:lifeos/features/permissions/presentation/permissions_onboarding_screen.dart';
import 'package:lifeos/features/permissions/presentation/permissions_providers.dart';
import 'package:lifeos/features/security/domain/biometric_authenticator.dart';
import 'package:lifeos/features/security/presentation/app_lock_providers.dart';
import 'package:lifeos/features/security/presentation/lock_screen.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../features/chat/support/fake_chat_gateways.dart';
import '../features/security/support/fakes.dart';
import '../features/stt/support/fake_stt.dart';
import 'support/golden_harness.dart';

class _Gateway implements PermissionsGateway {
  @override
  Future<PermissionState> status(AppPermission permission) async =>
      PermissionState.denied;

  @override
  Future<PermissionState> request(AppPermission permission) async =>
      PermissionState.granted;

  @override
  Future<bool> openSettings() async => true;
}

class _Preferences implements OnboardingPreferences {
  @override
  Future<bool> isPermissionsOnboardingDone() async => false;

  @override
  Future<void> markPermissionsOnboardingDone() async {}
}

const _installed =
    SttModelPaths(encoder: 'e.onnx', decoder: 'd.onnx', tokens: 't.txt');

Widget _host(Widget home) => ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: goldenTheme(),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

Future<void> _shoot(WidgetTester tester, String name) => expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/$name.png'),
    );

void main() {
  Future<void> pumpOnboarding(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/onboarding',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('home'))),
        GoRoute(
          path: '/onboarding',
          builder: (_, _) => const PermissionsOnboardingScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hostOperatingSystemProvider.overrideWithValue('android'),
        permissionsGatewayProvider.overrideWithValue(_Gateway()),
        onboardingPreferencesProvider.overrideWithValue(_Preferences()),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: goldenTheme(),
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('golden: onboarding greeting', (tester) async {
    useGoldenSurface(tester);
    await pumpOnboarding(tester);
    await _shoot(tester, 'remaining_onboarding_greeting');
  });

  testWidgets('golden: onboarding permissions', (tester) async {
    useGoldenSurface(tester);
    await pumpOnboarding(tester);
    await tester.tap(find.text(kFirstDayLookAround));
    await tester.pumpAndSettle();
    await _shoot(tester, 'remaining_onboarding');
  });

  testWidgets('golden: lock', (tester) async {
    useGoldenSurface(tester);
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
        debugShowCheckedModeBanner: false,
        theme: goldenTheme(),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LockScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    await _shoot(tester, 'remaining_lock');
  });

  Widget dictate() => ProviderScope(
        overrides: [
          hostOperatingSystemProvider.overrideWithValue('android'),
          audioRecorderGatewayProvider
              .overrideWithValue(FakeAudioRecorderGateway(path: '/tmp/take.wav')),
          speechToTextProvider.overrideWithValue(FakeSpeechToText(
            transcript: 'Recuérdame comprar pan y llamar a mi hermana mañana.',
          )),
          sttModelGatewayProvider
              .overrideWithValue(FakeSttModelGateway(installed: _installed)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: goldenTheme(),
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DictateScreen(),
        ),
      );

  testWidgets('golden: dictate idle', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(dictate());
    await tester.pumpAndSettle();
    await _shoot(tester, 'remaining_dictate');
  });

  testWidgets('golden: dictate transcript', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(dictate());
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(DictateScreen.micButtonKey));
      await tester.pumpAndSettle();
    }
    await _shoot(tester, 'remaining_dictate_transcript');
  });

  testWidgets('golden: desahogo', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(_host(const ConfessionScreen()));
    await tester.pumpAndSettle();
    await _shoot(tester, 'remaining_desahogo');
  });
}
