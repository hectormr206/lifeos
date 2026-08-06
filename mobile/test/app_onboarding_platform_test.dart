// Proves first-launch permissions onboarding is platform-honest.
//
// On Android it is unchanged — that gate is on the user's Pixel and a
// regression there would strand a real first launch. On Linux there is no
// runtime-permission model at all (`permission_handler` ships android/ios
// only), so the screen would greet a new desktop user with a list of things
// that all read "No disponible" and a "grant them all" button that grants
// nothing. That is the definition of a control the platform cannot honour, so
// it is skipped rather than shown.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/permissions/domain/onboarding_preferences.dart';
import 'package:lifeos/features/permissions/presentation/permissions_providers.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import 'support/fake_token_store.dart';

/// A first launch: onboarding has never been completed.
class _FirstLaunchPreferences implements OnboardingPreferences {
  bool stored = false;

  @override
  Future<bool> isPermissionsOnboardingDone() async => stored;

  @override
  Future<void> markPermissionsOnboardingDone() async => stored = true;
}

ProviderContainer _container(String operatingSystem) {
  final container = ProviderContainer(overrides: [
    hostOperatingSystemProvider.overrideWithValue(operatingSystem),
    tokenStoreProvider.overrideWithValue(FakeTokenStore()),
    onboardingPreferencesProvider.overrideWithValue(_FirstLaunchPreferences()),
    localeProvider.overrideWithValue(const Locale('es')),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  testWidgets('Android still routes a first launch to /onboarding',
      (tester) async {
    final container = _container('android');
    await container.read(onboardingGateProvider.notifier).ready;

    await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pumpAndSettle();

    expect(
      find.text('Permisos de LifeOS'),
      findsOneWidget,
      reason: 'the Pixel first-launch flow must not change',
    );
  });

  testWidgets('Linux skips it — there is no runtime permission to grant',
      (tester) async {
    final container = _container('linux');
    await container.read(onboardingGateProvider.notifier).ready;

    await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pumpAndSettle();

    expect(find.text('Permisos de LifeOS'), findsNothing);
  });
}
