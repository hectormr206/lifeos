// Builds the REAL `LifeOSApp` once per supported OS and asserts no
// `FlutterError` escapes the first frames.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT THIS DOES NOT CATCH — read before trusting it.
//
// It does NOT prove the app starts on Android. Under `flutter test` there are
// no plugins: every platform channel returns null or throws
// `MissingPluginException`, and the harness swallows those rather than
// surfacing them the way a real embedder would. The startup crash that reached
// the user's Pixel was almost certainly exactly that — a plugin call — and a
// throwaway version of THIS test passed cleanly for android while the real
// build was broken. It was written, it was green, and it was useless for that
// bug. That is measured, not assumed.
//
// What it IS for: the narrower class where the Dart itself is wrong on one
// platform — a desktop-only widget constructed on the mobile path, a provider
// that returns null on Android and is then dereferenced, a router redirect
// that loops on one OS. Those raise a real `FlutterError` here, on the OS that
// has the bug and not on the other, which is precisely what a single-OS suite
// running on the linux build host could never show.
//
// Device coverage is the Pixel over adb. Not this file.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/features/permissions/domain/onboarding_preferences.dart';
import 'package:lifeos/features/permissions/presentation/permissions_providers.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import 'support/fake_token_store.dart';
import 'support/platform_matrix.dart';

/// Onboarding already done, so the app lands on the real home shell on BOTH
/// platforms. Otherwise Android would route to `/onboarding` and the matrix
/// would be comparing two different screens.
class _OnboardedPreferences implements OnboardingPreferences {
  @override
  Future<bool> isPermissionsOnboardingDone() async => true;

  @override
  Future<void> markPermissionsOnboardingDone() async {}
}

void main() {
  testPerOperatingSystem('LifeOSApp startup', (operatingSystem) {
    testWidgets('builds without raising a FlutterError', (tester) async {
      final container = ProviderContainer(overrides: [
        hostOperatingSystemProvider.overrideWithValue(operatingSystem),
        tokenStoreProvider.overrideWithValue(FakeTokenStore()),
        onboardingPreferencesProvider.overrideWithValue(_OnboardedPreferences()),
        localeProvider.overrideWithValue(const Locale('es')),
      ]);
      addTearDown(container.dispose);
      await container.read(onboardingGateProvider.notifier).ready;

      // Collect rather than let the harness report: `pumpWidget` reports the
      // FIRST error and swallows later ones, and the platform-specific failure
      // is often the second or third.
      final errors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const LifeOSApp(),
      ));
      // NOT pumpAndSettle: the home screen carries Axi's avatar, which animates
      // forever, so the tree never settles. These pumps run the router redirect,
      // the first real frame, and the post-frame startup callbacks.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        errors.map((e) => e.exceptionAsString()).toList(),
        isEmpty,
        reason: 'building LifeOSApp as "$operatingSystem" raised errors that '
            'the other platform does not. See the file header for the large '
            'class of startup failure this CANNOT see.',
      );
      expect(find.byType(LifeOSApp), findsOneWidget);
    });
  });
}
