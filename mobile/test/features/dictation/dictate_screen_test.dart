// Proves the Dictar screen: the mic toggles a take, the transcript comes back
// editable, and every failure is stated on screen rather than swallowed.
//
// This machine is HEADLESS — no display, no audio device. Nothing here touches
// a real microphone or the sherpa-onnx runtime; the three seams are faked, the
// same way the chat voice-note suite does it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/dictation/presentation/dictate_screen.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../chat/support/fake_chat_gateways.dart';
import '../stt/support/fake_stt.dart';

const _installed = SttModelPaths(encoder: 'e.onnx', decoder: 'd.onnx', tokens: 't.txt');

Widget _app({
  FakeAudioRecorderGateway? recorder,
  FakeSpeechToText? stt,
  FakeSttModelGateway? model,
  String operatingSystem = 'android',
}) =>
    ProviderScope(
      overrides: [
        hostOperatingSystemProvider.overrideWithValue(operatingSystem),
        audioRecorderGatewayProvider
            .overrideWithValue(recorder ?? FakeAudioRecorderGateway()),
        speechToTextProvider
            .overrideWithValue(stt ?? FakeSpeechToText(transcript: 'hola axi')),
        sttModelGatewayProvider
            .overrideWithValue(model ?? FakeSttModelGateway(installed: _installed)),
      ],
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const DictateScreen(),
      ),
    );

Future<void> _tapMic(WidgetTester tester) async {
  await tester.tap(find.byKey(DictateScreen.micButtonKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens with the tagline and an idle mic', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Dictar'), findsWidgets);
    expect(find.text('Habla y Axi te escucha'), findsOneWidget);
    expect(find.text('Toca el micrófono y habla'), findsOneWidget);
    expect(find.byKey(DictateScreen.micButtonKey), findsOneWidget);
  });

  testWidgets('tap starts a take, tap again transcribes it into an editable field',
      (tester) async {
    final recorder = FakeAudioRecorderGateway(path: '/tmp/take.wav');
    await tester.pumpWidget(_app(
      recorder: recorder,
      stt: FakeSpeechToText(transcript: 'recordame comprar pan'),
    ));
    await tester.pumpAndSettle();

    await _tapMic(tester);
    expect(find.text('Te escucho… toca para terminar'), findsOneWidget);
    expect(recorder.startCount, 1);

    await _tapMic(tester);
    expect(recorder.stopCount, 1);

    // The transcript lands in a field the user can edit before sending — the
    // brief said "put the text where the user can use it".
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'recordame comprar pan');
    expect(find.text('Enviar a Axi'), findsOneWidget);
    expect(find.text('Copiar'), findsOneWidget);
  });

  group('failures are visible on screen', () {
    testWidgets('a missing voice model offers the download', (tester) async {
      await tester.pumpWidget(_app(model: FakeSttModelGateway(installed: null)));
      await tester.pumpAndSettle();

      await _tapMic(tester);

      expect(find.text('El modelo de voz no está descargado en este dispositivo.'),
          findsOneWidget);
      // The one failure the user can fix in-app, so it gets an action.
      expect(find.text('Descargar modelo de voz'), findsOneWidget);
    });

    testWidgets('a denied microphone permission is stated', (tester) async {
      await tester.pumpWidget(_app(recorder: FakeAudioRecorderGateway(permission: false)));
      await tester.pumpAndSettle();

      await _tapMic(tester);

      expect(find.text('Sin permiso de micrófono, no puedo escucharte.'), findsOneWidget);
    });

    testWidgets(
        'on desktop a recorder that will not open explains parecord/ffmpeg',
        (tester) async {
      await tester.pumpWidget(_app(
        recorder: FakeAudioRecorderGateway(
          startError: Exception('parecord: command not found'),
        ),
        operatingSystem: 'linux',
      ));
      await tester.pumpAndSettle();

      await _tapMic(tester);

      expect(find.text('No se pudo abrir el micrófono.'), findsOneWidget);
      expect(find.textContaining('parecord'), findsWidgets);
      // The concrete fix, since the installer only warns about these two.
      expect(find.textContaining('pacman'), findsOneWidget);
    });

    testWidgets('on Android the same failure does NOT show the Linux hint',
        (tester) async {
      await tester.pumpWidget(_app(
        recorder: FakeAudioRecorderGateway(startError: Exception('mic busy')),
        operatingSystem: 'android',
      ));
      await tester.pumpAndSettle();

      await _tapMic(tester);

      expect(find.text('No se pudo abrir el micrófono.'), findsOneWidget);
      expect(find.textContaining('pacman'), findsNothing);
    });

    testWidgets('an unintelligible take says so instead of showing a blank field',
        (tester) async {
      await tester.pumpWidget(_app(stt: FakeSpeechToText(transcript: '  ')));
      await tester.pumpAndSettle();

      await _tapMic(tester);
      await _tapMic(tester);

      expect(find.textContaining('No se entendió nada'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('a failure can be retried', (tester) async {
      await tester.pumpWidget(_app(recorder: FakeAudioRecorderGateway(permission: false)));
      await tester.pumpAndSettle();

      await _tapMic(tester);
      expect(find.text('Probar de nuevo'), findsOneWidget);

      await tester.tap(find.text('Probar de nuevo'));
      await tester.pumpAndSettle();

      expect(find.text('Toca el micrófono y habla'), findsOneWidget);
    });
  });

  testWidgets('discard clears the transcript back to the idle prompt',
      (tester) async {
    await tester.pumpWidget(_app(stt: FakeSpeechToText(transcript: 'algo')));
    await tester.pumpAndSettle();

    await _tapMic(tester);
    await _tapMic(tester);
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Toca el micrófono y habla'), findsOneWidget);
  });

  testWidgets('leaving the screen mid-take releases the microphone',
      (tester) async {
    // A hot mic outliving its screen is the bug the chat composer's
    // pointer-cancel path exists to prevent; the same must hold here.
    final recorder = FakeAudioRecorderGateway();
    await tester.pumpWidget(_app(recorder: recorder));
    await tester.pumpAndSettle();

    await _tapMic(tester);
    expect(recorder.startCount, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    expect(recorder.cancelCount, 1);
  });
}
