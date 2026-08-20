// The two permissions SCREENS, once per platform.
//
// `permissionsForPlatform(os)` was already proven correct as a pure function
// (test/features/permissions/domain/app_permission_platform_test.dart). What
// nothing proved is that the screens actually USE it: both call it through
// `ref.read(hostOperatingSystemProvider)`, and until this file existed neither
// screen had a widget test at all. On the linux build host they would have
// rendered the desktop list forever and nobody would have noticed the Android
// one drifting.
//
// The difference that matters: `installUnknownApps`
// (REQUEST_INSTALL_PACKAGES) exists only where the OTA update IS an APK. On
// Android the row is present and onboarding requests it; on Linux — where the
// updater is the `lifeos-updater` systemd unit — asking the user to approve
// it would be asking for something that can never happen.
//
// See test/support/platform_matrix.dart for what a green matrix does NOT
// prove: `permission_handler` has no plugin here, so this exercises the Dart
// branches only, never a real OS dialog.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/first_day/domain/first_day_copy.dart';
import 'package:lifeos/features/permissions/domain/app_permission.dart';
import 'package:lifeos/features/permissions/domain/onboarding_preferences.dart';
import 'package:lifeos/features/permissions/domain/permissions_gateway.dart';
import 'package:lifeos/features/permissions/presentation/permissions_onboarding_screen.dart';
import 'package:lifeos/features/permissions/presentation/permissions_providers.dart';
import 'package:lifeos/features/permissions/presentation/permissions_screen.dart';

import '../../../support/platform_matrix.dart';

/// Records what was asked for, so the onboarding test can assert the REQUEST
/// list rather than only what is painted.
class _RecordingGateway implements PermissionsGateway {
  final List<AppPermission> requested = <AppPermission>[];
  int settingsOpened = 0;

  @override
  Future<PermissionState> status(AppPermission permission) async =>
      PermissionState.denied;

  @override
  Future<PermissionState> request(AppPermission permission) async {
    requested.add(permission);
    return PermissionState.granted;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}

class _NoopPreferences implements OnboardingPreferences {
  bool done = false;

  @override
  Future<bool> isPermissionsOnboardingDone() async => done;

  @override
  Future<void> markPermissionsOnboardingDone() async => done = true;
}

/// The permission rows the platform is expected to show, derived from the same
/// pure function the screens use. Asserted against a hard-coded expectation
/// below so a change in `permissionsForPlatform` cannot silently redefine what
/// this test considers correct.
List<AppPermission> _expected(String operatingSystem) =>
    permissionsForPlatform(operatingSystem);

void main() {
  test('the matrix platforms genuinely differ — otherwise these tests are noise', () {
    // If Android and Linux ever showed the same list, every assertion below
    // would pass for the wrong reason. Pin the actual difference.
    expect(_expected('android'), contains(AppPermission.installUnknownApps));
    expect(_expected('linux'), isNot(contains(AppPermission.installUnknownApps)));
  });

  testPerOperatingSystem('PermissionsScreen', (operatingSystem) {
    testWidgets('lists exactly the permissions this platform has',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          hostOperatingSystemProvider.overrideWithValue(operatingSystem),
          permissionsGatewayProvider.overrideWithValue(_RecordingGateway()),
        ],
        child: const MaterialApp(home: PermissionsScreen()),
      ));
      await tester.pump();

      for (final permission in AppPermission.values) {
        final shouldShow = _expected(operatingSystem).contains(permission);
        expect(
          find.text(permission.title),
          shouldShow ? findsOneWidget : findsNothing,
          reason: '${permission.name} should '
              '${shouldShow ? 'appear' : 'be absent'} on $operatingSystem',
        );
      }
      expect(find.byType(ListTile), findsNWidgets(_expected(operatingSystem).length));
    });
  });

  testPerOperatingSystem('PermissionsOnboardingScreen', (operatingSystem) {
    testWidgets('requests exactly the permissions this platform has',
        (tester) async {
      // Taller than the default 800x600: the onboarding rows are large, and on
      // Android the fifth one (Instalar apps) falls outside the viewport, where
      // the ListView never builds it. That would read as "the row is missing on
      // Android" — the exact false negative this file exists to prevent.
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final gateway = _RecordingGateway();
      final preferences = _NoopPreferences();
      // A real (tiny) GoRouter: `_grantAll` ends in `_finish()` →
      // `context.go('/')`, so without one the request loop under test would
      // throw before it could be asserted.
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
          hostOperatingSystemProvider.overrideWithValue(operatingSystem),
          permissionsGatewayProvider.overrideWithValue(gateway),
          onboardingPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pump();

      // El primer día empieza por la presentación: los permisos están detrás
      // de "Prefiero mirar primero". Sin este paso, lo de abajo buscaría filas
      // que todavía no existen.
      await tester.tap(find.text(kFirstDayLookAround));
      await tester.pumpAndSettle();

      for (final permission in AppPermission.values) {
        final shouldShow = _expected(operatingSystem).contains(permission);
        expect(
          find.text(permission.title),
          shouldShow ? findsOneWidget : findsNothing,
          reason: '${permission.name} listed on $operatingSystem?',
        );
      }

      await tester.tap(find.widgetWithText(FilledButton, 'Activar permisos'));
      await tester.pumpAndSettle();

      expect(
        preferences.done,
        isTrue,
        reason: 'onboarding must complete on $operatingSystem, or the user is '
            'trapped on this screen forever',
      );
      expect(
        gateway.requested,
        _expected(operatingSystem),
        reason: 'onboarding on $operatingSystem must never ask the OS for a '
            'grant that cannot exist there',
      );
    });
  });
}
