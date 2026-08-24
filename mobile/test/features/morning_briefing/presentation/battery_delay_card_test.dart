// Decirle al usuario POR QUÉ su boletín llega tarde, y dejarle arreglarlo.
//
// Medido en el Pixel de pruebas el 2026-08-24: Android tenía LifeOS en el
// bucket de reposo RARE y sin exención de batería, y arrancó la tarea diez
// minutos después de la hora. La app no puede evitarlo sola — pero puede decir
// qué pasa y ofrecer el permiso que lo arregla.
//
// Es del usuario decidir: la tarjeta ofrece, nunca pide sola al abrir la app.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_schedule.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_providers.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_screen.dart';
import 'package:lifeos/features/permissions/domain/app_permission.dart';
import 'package:lifeos/features/permissions/domain/permissions_gateway.dart';
import 'package:lifeos/features/permissions/presentation/permissions_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../local_model/support/fake_local_llm_engine.dart';
import '../support/fakes.dart';

class _FixedClock implements Clock {
  const _FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime now() => _now;
}

class _Gateway implements PermissionsGateway {
  _Gateway(this._state);

  final PermissionState _state;
  final List<AppPermission> requested = [];

  @override
  Future<PermissionState> status(AppPermission permission) async => _state;

  @override
  Future<PermissionState> request(AppPermission permission) async {
    requested.add(permission);
    return PermissionState.granted;
  }

  @override
  Future<bool> openSettings() async => true;
}

OnDeviceBriefing _briefing() => OnDeviceBriefing(
      generatedAt: DateTime(2026, 7, 22, 8),
      articles: const [
        BriefingArticle(
          sourceName: 'F',
          section: 'Mundo',
          title: 'Una noticia',
          url: 'https://a.com/1',
          description: 'detalle',
        ),
      ],
    );

Future<void> _pump(
  WidgetTester tester,
  _Gateway gateway, {
  bool scheduleEnabled = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        permissionsGatewayProvider.overrideWithValue(gateway),
        morningBriefingPreferencesProvider.overrideWithValue(
          FakeMorningBriefingPreferences(
            initialBriefing: _briefing(),
            initialSchedule: BriefingSchedule(enabled: scheduleEnabled),
          ),
        ),
        localLlmEngineProvider.overrideWithValue(
          FakeLocalLlmEngine(installed: true),
        ),
        sourceFetcherProvider.overrideWithValue(FakeSourceFetcher()),
        briefingNotificationsProvider.overrideWithValue(
          FakeBriefingNotifications(),
        ),
        briefingSchedulerProvider.overrideWithValue(FakeBriefingScheduler()),
        clockProvider.overrideWithValue(_FixedClock(DateTime(2026, 7, 22, 9))),
      ],
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const MorningBriefingScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('si Android puede retrasarlo, la pantalla lo dice y lo ofrece',
      (tester) async {
    final gateway = _Gateway(PermissionState.denied);

    await _pump(tester, gateway);

    expect(find.textContaining('retrasar'), findsOneWidget);
    expect(
      gateway.requested,
      isEmpty,
      reason: 'ofrece; no pide sola al abrir la pantalla',
    );
  });

  testWidgets('tocar el botón pide el permiso', (tester) async {
    final gateway = _Gateway(PermissionState.denied);
    await _pump(tester, gateway);

    await tester.tap(find.text('Permitir'));
    await tester.pumpAndSettle();

    expect(gateway.requested, [AppPermission.batteryUnrestricted]);
  });

  testWidgets('concedido: no queda ni rastro de la tarjeta', (tester) async {
    await _pump(tester, _Gateway(PermissionState.granted));
    expect(find.textContaining('retrasar'), findsNothing);
  });

  testWidgets('sin boletín automático no hay nada que retrasar', (tester) async {
    await _pump(tester, _Gateway(PermissionState.denied),
        scheduleEnabled: false);
    expect(find.textContaining('retrasar'), findsNothing);
  });

  testWidgets('donde el permiso no existe, no se inventa una tarjeta',
      (tester) async {
    await _pump(tester, _Gateway(PermissionState.unsupported));
    expect(find.textContaining('retrasar'), findsNothing);
  });
}
