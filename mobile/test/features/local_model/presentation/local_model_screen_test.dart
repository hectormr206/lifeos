// Widget test for the model-manager screen (roadmap SLICE 1): renders the
// "usar modelo local" toggle + "descargar modelo" action, reflects installed
// state, and flips the toggle through the notifier. Fakes the engine + prefs
// so nothing real is downloaded.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/features/local_model/domain/notification_permission.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/local_model/presentation/local_model_screen.dart';

import '../support/fake_brain_model_ota.dart';
import '../support/fake_local_llm_engine.dart';

Future<void> _pump(
  WidgetTester tester, {
  required bool installed,
  bool enabled = false,
  FakeLocalLlmEngine? engine,
  FakeNotificationPermissionGateway? gateway,
  FakeBrainModelUpdateGateway? brainGateway,
  FakeBrainModelVersionStore? versionStore,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const LocalModelScreen()),
      GoRoute(path: '/chat', builder: (context, state) => const Scaffold(body: Text('CHAT'))),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localLlmEngineProvider.overrideWithValue(engine ?? FakeLocalLlmEngine(installed: installed)),
        localModelPreferencesProvider.overrideWithValue(FakeLocalModelPreferences(enabled: enabled)),
        notificationPermissionGatewayProvider
            .overrideWithValue(gateway ?? FakeNotificationPermissionGateway()),
        // In-memory OTA fakes: the real gateway/store would hit
        // path_provider / shared_preferences platform channels in a widget
        // test (unconfigured by default, but delete/bootstrap still touch
        // them) and hang pumpAndSettle.
        brainModelUpdateGatewayProvider
            .overrideWithValue(brainGateway ?? FakeBrainModelUpdateGateway(configured: false)),
        brainModelVersionStoreProvider
            .overrideWithValue(versionStore ?? FakeBrainModelVersionStore()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the toggle and a download button when not installed', (tester) async {
    await _pump(tester, installed: false);

    expect(find.text('Usar modelo local'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Descargar modelo'), findsOneWidget);
    expect(find.text('Modelo no descargado'), findsOneWidget);
  });

  testWidgets('shows installed state and no download button when installed', (tester) async {
    await _pump(tester, installed: true);

    expect(find.text('Modelo instalado'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Descargar modelo'), findsNothing);
  });

  testWidgets('toggle is DISABLED with a helper hint when the model is absent', (tester) async {
    await _pump(tester, installed: false);

    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    // A null onChanged means the switch is greyed out / non-interactive.
    expect(tile.onChanged, isNull);
    expect(tile.value, isFalse);
    expect(find.text('Descargá el modelo primero.'), findsOneWidget);
  });

  testWidgets('tapping the toggle turns on local mode when the model is installed', (tester) async {
    await _pump(tester, installed: true);

    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
  });

  testWidgets('shows the notification rationale next to the download button', (tester) async {
    await _pump(tester, installed: false);

    expect(
      find.textContaining('Activá las notificaciones para ver el progreso'),
      findsOneWidget,
    );
  });

  testWidgets('soft denial shows an informative notice and keeps the download button', (tester) async {
    // Denied + download fails => stays not installed so the notice is visible.
    await _pump(
      tester,
      installed: false,
      engine: FakeLocalLlmEngine(downloadShouldFail: true),
      gateway: FakeNotificationPermissionGateway(requestResult: NotificationPermission.denied),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Descargar modelo'));
    await tester.pumpAndSettle();

    expect(find.textContaining('la descarga funciona igual'), findsOneWidget);
    // Re-request affordance: the (retry) download button is still there.
    expect(find.byType(FilledButton), findsOneWidget);
    // No permanent-denial escape hatch on a soft denial.
    expect(find.widgetWithText(TextButton, 'Abrir ajustes'), findsNothing);
  });

  testWidgets('permanent denial shows an "Abrir ajustes" button that deep-links', (tester) async {
    final gateway =
        FakeNotificationPermissionGateway(requestResult: NotificationPermission.permanentlyDenied);
    await _pump(
      tester,
      installed: false,
      engine: FakeLocalLlmEngine(downloadShouldFail: true),
      gateway: gateway,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Descargar modelo'));
    await tester.pumpAndSettle();

    final settingsButton = find.widgetWithText(TextButton, 'Abrir ajustes');
    expect(settingsButton, findsOneWidget);
    expect(find.textContaining('activalas desde Ajustes'), findsOneWidget);

    await tester.tap(settingsButton);
    await tester.pumpAndSettle();
    expect(gateway.openSettingsCount, 1);
  });

  testWidgets('shows the "nuevo modelo disponible" banner when the manifest is newer', (tester) async {
    await _pump(
      tester,
      installed: true,
      brainGateway: FakeBrainModelUpdateGateway(
        manifest: brainManifest(versionCode: 2, notes: 'Recipe re-tuned'),
      ),
      versionStore: FakeBrainModelVersionStore(),
    );

    expect(find.text('Hay un nuevo modelo disponible'), findsOneWidget);
    expect(find.text('Recipe re-tuned'), findsOneWidget);
    expect(find.textContaining('Actualizar modelo'), findsOneWidget);
  });

  testWidgets('no update banner when the installed model is current', (tester) async {
    await _pump(
      tester,
      installed: true,
      brainGateway: FakeBrainModelUpdateGateway(manifest: brainManifest(versionCode: 1)),
      versionStore: FakeBrainModelVersionStore(),
    );

    expect(find.text('Hay un nuevo modelo disponible'), findsNothing);
  });

  testWidgets('tapping "Actualizar modelo" runs the update through the gateway', (tester) async {
    final engine = FakeLocalLlmEngine(installed: true);
    final brainGateway = FakeBrainModelUpdateGateway(manifest: brainManifest(versionCode: 2));
    final versionStore = FakeBrainModelVersionStore();
    await _pump(
      tester,
      installed: true,
      engine: engine,
      brainGateway: brainGateway,
      versionStore: versionStore,
    );
    expect(find.text('Hay un nuevo modelo disponible'), findsOneWidget);

    await tester.tap(find.textContaining('Actualizar modelo'));
    await tester.pumpAndSettle();

    expect(brainGateway.downloadCount, 1);
    expect(engine.installedFromFilePaths, hasLength(1));
    expect(versionStore.value?.versionCode, 2);
    expect(find.text('Hay un nuevo modelo disponible'), findsNothing);
  });

  testWidgets('shows "Eliminar modelo" when the model is installed', (tester) async {
    await _pump(tester, installed: true);
    expect(find.widgetWithText(OutlinedButton, 'Eliminar modelo'), findsOneWidget);
  });

  testWidgets('hides "Eliminar modelo" when the model is not installed', (tester) async {
    await _pump(tester, installed: false);
    expect(find.widgetWithText(OutlinedButton, 'Eliminar modelo'), findsNothing);
  });

  testWidgets('hides "Ir al chat" when installed but the toggle is off', (tester) async {
    await _pump(tester, installed: true, enabled: false);
    expect(find.widgetWithText(FilledButton, 'Ir al chat'), findsNothing);
  });

  testWidgets('shows "Ir al chat" when installed and the toggle is on', (tester) async {
    await _pump(tester, installed: true, enabled: true);
    expect(find.widgetWithText(FilledButton, 'Ir al chat'), findsOneWidget);
  });

  testWidgets('"Ir al chat" navigates to the chat screen', (tester) async {
    await _pump(tester, installed: true, enabled: true);

    await tester.tap(find.widgetWithText(FilledButton, 'Ir al chat'));
    await tester.pumpAndSettle();

    expect(find.text('CHAT'), findsOneWidget);
  });

  testWidgets('"Eliminar modelo" opens a confirm dialog with the freed-space copy', (tester) async {
    await _pump(tester, installed: true);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Eliminar modelo'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Se liberarán ~2.6 GB'), findsOneWidget);
    expect(find.textContaining('Podrás volver a descargarlo'), findsOneWidget);
  });

  testWidgets('confirming deletion removes the model and restores the download button', (tester) async {
    final engine = FakeLocalLlmEngine(installed: true);
    await _pump(tester, installed: true, engine: engine);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Eliminar modelo'));
    await tester.pumpAndSettle();
    // Confirm in the dialog.
    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
    await tester.pumpAndSettle();

    expect(engine.deleteCount, 1);
    expect(find.text('Modelo no descargado'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Descargar modelo'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Eliminar modelo'), findsNothing);
  });

  testWidgets('cancelling the delete dialog keeps the model installed', (tester) async {
    final engine = FakeLocalLlmEngine(installed: true);
    await _pump(tester, installed: true, engine: engine);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Eliminar modelo'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await tester.pumpAndSettle();

    expect(engine.deleteCount, 0);
    expect(find.text('Modelo instalado'), findsOneWidget);
  });

  testWidgets('a delete failure surfaces an error and keeps the model', (tester) async {
    final engine = FakeLocalLlmEngine(installed: true, deleteShouldFail: true);
    await _pump(tester, installed: true, engine: engine);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Eliminar modelo'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No se pudo eliminar'), findsOneWidget);
    expect(find.text('Modelo instalado'), findsOneWidget);
  });
}
