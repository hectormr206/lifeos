// Widget test for the model-manager screen (roadmap SLICE 1): renders the
// "usar modelo local" toggle + "descargar modelo" action, reflects installed
// state, and flips the toggle through the notifier. Fakes the engine + prefs
// so nothing real is downloaded.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/local_model/presentation/local_model_screen.dart';

import '../support/fake_local_llm_engine.dart';

Future<void> _pump(WidgetTester tester, {required bool installed}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: installed)),
        localModelPreferencesProvider.overrideWithValue(FakeLocalModelPreferences()),
      ],
      child: const MaterialApp(home: LocalModelScreen()),
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
}
