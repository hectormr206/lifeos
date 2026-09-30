import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/core/widgets/widgets.dart';
import 'package:lifeos/features/first_day/domain/first_day_copy.dart';
import 'package:lifeos/features/permissions/domain/app_permission.dart';
import 'package:lifeos/features/permissions/domain/onboarding_preferences.dart';
import 'package:lifeos/features/permissions/domain/permissions_gateway.dart';
import 'package:lifeos/features/permissions/presentation/permissions_onboarding_screen.dart';
import 'package:lifeos/features/permissions/presentation/permissions_providers.dart';
import 'package:lifeos/theme/lifeos_theme.dart';

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

void main() {
  testWidgets('permissions are one grouped list under a display title',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
      child: MaterialApp.router(theme: lifeosLightTheme, routerConfig: router),
    ));
    await tester.pump();
    await tester.tap(find.text(kFirstDayLookAround));
    await tester.pumpAndSettle();

    final rows = find.descendant(
      of: find.byType(GroupedList),
      matching: find.byType(GroupedRow),
    );
    expect(find.byType(GroupedList), findsOneWidget);
    expect(rows, findsNWidgets(permissionsForPlatform('android').length));

    final title = tester.widget<Text>(find.text('Permisos de LifeOS'));
    expect(title.style?.fontSize, lifeosLightTheme.textTheme.displaySmall?.fontSize);
    expect(find.byType(Image), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Activar permisos'), findsOneWidget);
  });
}
