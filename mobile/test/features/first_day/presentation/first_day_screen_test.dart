// El primer día, tal como se ve en un teléfono.
//
// Que los textos EXISTAN no prueba que alguien los lea: un widget fuera de
// pantalla, tapado o de área cero también pasa un find.text. Y la superficie
// por defecto de las pruebas (800x600) no es ningún teléfono. Así que aquí se
// mide contra un tamaño real de Pixel.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/features/first_day/domain/first_day_copy.dart';
import 'package:lifeos/features/permissions/domain/app_permission.dart';
import 'package:lifeos/features/permissions/domain/onboarding_preferences.dart';
import 'package:lifeos/features/permissions/domain/permissions_gateway.dart';
import 'package:lifeos/features/permissions/presentation/permissions_onboarding_screen.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/permissions/presentation/permissions_providers.dart';

class _Gateway implements PermissionsGateway {
  @override
  Future<PermissionState> status(AppPermission p) async =>
      PermissionState.denied;
  @override
  Future<PermissionState> request(AppPermission p) async =>
      PermissionState.granted;
  @override
  Future<bool> openSettings() async => true;
}

class _Prefs implements OnboardingPreferences {
  bool done = false;
  @override
  Future<bool> isPermissionsOnboardingDone() async => done;
  @override
  Future<void> markPermissionsOnboardingDone() async => done = true;
}

/// Dónde acabó el usuario. Es lo que de verdad se está probando: no el texto,
/// sino a dónde lleva.
late String landedOn;

Future<_Prefs> _pumpFirstDay(WidgetTester tester) async {
  // Un Pixel, no la superficie por defecto de las pruebas.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);

  landedOn = '/onboarding';
  final prefs = _Prefs();
  final router = GoRouter(
    initialLocation: '/onboarding',
    routes: [
      GoRoute(path: '/', builder: (_, _) {
        landedOn = '/';
        return const Scaffold(body: Text('inicio'));
      }),
      GoRoute(path: '/chat', builder: (_, _) {
        landedOn = '/chat';
        return const Scaffold(body: Text('chat'));
      }),
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
      onboardingPreferencesProvider.overrideWithValue(prefs),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pump();
  return prefs;
}

void main() {
  testWidgets('lo primero es la presentación, no el trámite', (tester) async {
    await _pumpFirstDay(tester);

    expect(find.text(kFirstDayGreeting), findsOneWidget);
    expect(find.text(kFirstDayPromise), findsOneWidget);
    // Y los permisos NO están: eran lo primero que veía alguien que nunca
    // había oído hablar de esto.
    expect(find.text('Permisos de LifeOS'), findsNothing);
  });

  testWidgets('la promesa se ve entera y dentro de la pantalla',
      (tester) async {
    await _pumpFirstDay(tester);

    final size = tester.getSize(find.text(kFirstDayPromise));
    final topLeft = tester.getTopLeft(find.text(kFirstDayPromise));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;

    expect(size.height, greaterThan(0));
    expect(topLeft.dy, greaterThanOrEqualTo(0));
    expect(topLeft.dy + size.height, lessThan(screen.height),
        reason: 'la frase que decide si alguien se queda no puede estar fuera '
            'de la pantalla');
  });

  testWidgets('el botón principal lleva al chat', (tester) async {
    // Lo que engancha no es entender la app: es ver qué hace con la primera
    // cosa que le cuentas.
    final prefs = await _pumpFirstDay(tester);

    await tester.tap(find.widgetWithText(FilledButton, kFirstDayCallToAction));
    await tester.pumpAndSettle();

    expect(landedOn, '/chat');
    expect(prefs.done, isTrue,
        reason: 'quien ya entró no debe volver a ver la bienvenida');
  });

  testWidgets('se puede mirar primero, y entonces sí vienen los permisos',
      (tester) async {
    await _pumpFirstDay(tester);

    await tester.tap(find.text(kFirstDayLookAround));
    await tester.pumpAndSettle();

    expect(find.text('Permisos de LifeOS'), findsOneWidget);
  });

  testWidgets('el botón principal es alcanzable con el pulgar', (tester) async {
    // Un botón que exige hacer scroll para existir es un botón que la mitad de
    // la gente no encuentra.
    await _pumpFirstDay(tester);

    final button =
        tester.getRect(find.widgetWithText(FilledButton, kFirstDayCallToAction));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;

    expect(button.bottom, lessThanOrEqualTo(screen.height));
    expect(button.height, greaterThanOrEqualTo(44),
        reason: 'el mínimo táctil de una persona real');
  });
}
