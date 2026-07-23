import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/dictation/data/dictation_channel.dart';
import 'package:lifeos/features/dictation/presentation/dictation_providers.dart';
import 'package:lifeos/features/dictation/presentation/dictation_setup_screen.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/domain/stt_model_gateway.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';

/// Records calls instead of hitting the real `lifeos/dictation` channel.
class _FakeDictationChannel extends DictationChannel {
  _FakeDictationChannel({this.enabled = false, this.selected = false});

  bool enabled;
  bool selected;
  final List<String> calls = [];

  @override
  Future<void> openImeSettings() async => calls.add('openImeSettings');

  @override
  Future<void> showImePicker() async => calls.add('showImePicker');

  @override
  Future<bool> isImeEnabled() async => enabled;

  @override
  Future<bool> isImeSelected() async => selected;
}

class _FakeSttModelGateway implements SttModelGateway {
  _FakeSttModelGateway({required this.installed});

  final bool installed;

  @override
  Future<SttModelPaths?> installedModel() async => installed
      ? const SttModelPaths(encoder: 'e', decoder: 'd', tokens: 't')
      : null;

  @override
  Future<SttModelPaths> download({void Function(double progress)? onProgress}) async =>
      const SttModelPaths(encoder: 'e', decoder: 'd', tokens: 't');
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required _FakeDictationChannel channel,
  required bool modelInstalled,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dictationChannelProvider.overrideWithValue(channel),
        sttModelGatewayProvider.overrideWithValue(
          _FakeSttModelGateway(installed: modelInstalled),
        ),
      ],
      child: const MaterialApp(home: DictationSetupScreen()),
    ),
  );
  // Settle the IME-status future + the model-status hydration.
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders both setup steps and the privacy explanation', (tester) async {
    await _pumpScreen(
      tester,
      channel: _FakeDictationChannel(),
      modelInstalled: true,
    );

    expect(find.text('1. Activa el teclado Axi'), findsOneWidget);
    expect(find.text('2. Cambia al teclado Axi'), findsOneWidget);
    expect(find.textContaining('nunca salen del dispositivo'), findsOneWidget);
    expect(find.text('Modelo de voz listo'), findsOneWidget);
  });

  testWidgets('tapping step 1 opens the system IME settings', (tester) async {
    final channel = _FakeDictationChannel();
    await _pumpScreen(tester, channel: channel, modelInstalled: true);

    await tester.tap(find.text('Abrir ajustes de teclado'));
    expect(channel.calls, ['openImeSettings']);
  });

  testWidgets('step 2 is disabled until the keyboard is enabled', (tester) async {
    final channel = _FakeDictationChannel(enabled: false);
    await _pumpScreen(tester, channel: channel, modelInstalled: true);

    final pickerButton = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Elegir teclado'), matching: find.byType(FilledButton)),
    );
    expect(pickerButton.onPressed, isNull);
  });

  testWidgets('step 2 shows the keyboard picker once enabled', (tester) async {
    final channel = _FakeDictationChannel(enabled: true);
    await _pumpScreen(tester, channel: channel, modelInstalled: true);

    await tester.tap(find.text('Elegir teclado'));
    expect(channel.calls, ['showImePicker']);
  });

  testWidgets('everything set up shows all three checks', (tester) async {
    final channel = _FakeDictationChannel(enabled: true, selected: true);
    await _pumpScreen(tester, channel: channel, modelInstalled: true);

    // Step 1 + step 2 + voice-model card all report done.
    expect(find.byIcon(Icons.check_circle), findsNWidgets(3));
  });

  testWidgets('missing voice model shows the download affordance', (tester) async {
    await _pumpScreen(
      tester,
      channel: _FakeDictationChannel(),
      modelInstalled: false,
    );

    expect(
      find.text('Modelo de voz no descargado (el teclado lo necesita)'),
      findsOneWidget,
    );
    expect(find.text('Descargar modelo de voz'), findsOneWidget);
  });
}
