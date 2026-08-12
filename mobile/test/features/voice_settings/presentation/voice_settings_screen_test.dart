// Proves the "Voz" screen: the auto-speak switch reflects + sets the SHARED
// voice-reply preference, "Probar voz" speaks the sample through the shared
// gateway, and opening the screen proactively downloads the neural Piper voice
// so it becomes active. All engine/persistence seams are faked (no platform
// channels, no network).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/tts/domain/voice_test_outcome.dart';
import 'package:lifeos/features/tts/presentation/tts_providers.dart';
import 'package:lifeos/features/voice_settings/presentation/voice_settings_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/language_preference.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../../../support/fake_language_preferences.dart';
import '../../chat/support/fake_chat_gateways.dart' hide FakeTextToSpeechGateway;
import '../../tts/support/fake_tts.dart';

Widget _app({
  required FakeTextToSpeechGateway tts,
  required FakeVoiceReplyPreferences voiceReply,
  required FakeTtsVoiceGateway voiceGateway,
}) =>
    ProviderScope(
      overrides: [
        textToSpeechGatewayProvider.overrideWithValue(tts),
        voiceReplyPreferencesProvider.overrideWithValue(voiceReply),
        ttsVoiceGatewayProvider.overrideWithValue(voiceGateway),
        // Pin the app language so the download targets a known code.
        languagePreferencesProvider
            .overrideWithValue(FakeLanguagePreferences(initial: AppLanguage.es)),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: VoiceSettingsScreen(),
      ),
    );

void main() {
  testWidgets('auto-speak switch reflects the shared preference (default ON)', (tester) async {
    final voiceReply = FakeVoiceReplyPreferences(enabled: true);
    await tester.pumpWidget(_app(
      tts: FakeTextToSpeechGateway(),
      voiceReply: voiceReply,
      voiceGateway: FakeTtsVoiceGateway(),
    ));
    await tester.pumpAndSettle();

    final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(sw.value, isTrue);
  });

  testWidgets('toggling auto-speak off sets + persists the shared preference', (tester) async {
    final voiceReply = FakeVoiceReplyPreferences(enabled: true);
    await tester.pumpWidget(_app(
      tts: FakeTextToSpeechGateway(),
      voiceReply: voiceReply,
      voiceGateway: FakeTtsVoiceGateway(),
    ));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.byType(SwitchListTile)));
    expect(container.read(voiceReplyEnabledProvider), isTrue);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(container.read(voiceReplyEnabledProvider), isFalse);
    expect(voiceReply.persisted, isFalse);
  });

  testWidgets('"Probar voz" speaks the sample through the shared gateway', (tester) async {
    final tts = FakeTextToSpeechGateway();
    await tester.pumpWidget(_app(
      tts: tts,
      voiceReply: FakeVoiceReplyPreferences(),
      voiceGateway: FakeTtsVoiceGateway(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Probar voz'));
    await tester.pumpAndSettle();

    expect(tts.spoken, hasLength(1));
    expect(tts.spoken.single, contains('Axi'));
  });

  // The tap used to be a black hole: no spinner, no message, ~90 s of nothing.
  // These pin the two halves of the fix — immediate acknowledgement, and an
  // honest outcome that never reports more than actually happened.
  group('"Probar voz" feedback', () {
    Finder testButton() => find.ancestor(
          of: find.text('Probar voz'),
          matching: find.byType(FilledButton),
        );

    testWidgets('shows a spinner and disables the button while the test is in flight',
        (tester) async {
      final tts = FakeTextToSpeechGateway()..diagnosticGate = Completer<void>();
      await tester.pumpWidget(_app(
        tts: tts,
        voiceReply: FakeVoiceReplyPreferences(),
        voiceGateway: FakeTtsVoiceGateway(),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<FilledButton>(testButton()).onPressed, isNotNull);

      await tester.tap(find.text('Probar voz'));
      await tester.pump(); // the SAME frame as the tap — no await in between

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<FilledButton>(testButton()).onPressed, isNull,
          reason: 'a second tap would stack another synthesis run');

      tts.diagnosticGate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('a neural success resolves back to the idle button', (tester) async {
      final tts = FakeTextToSpeechGateway()
        ..nextOutcome = const VoiceTestSpoke(VoiceTestEngine.neural);
      await tester.pumpWidget(_app(
        tts: tts,
        voiceReply: FakeVoiceReplyPreferences(),
        voiceGateway: FakeTtsVoiceGateway(),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Probar voz'));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<FilledButton>(testButton()).onPressed, isNotNull);
    });

    testWidgets('a system-voice fallback says so instead of claiming the neural voice worked',
        (tester) async {
      final tts = FakeTextToSpeechGateway()
        ..nextOutcome = const VoiceTestSpoke(
          VoiceTestEngine.system,
          neuralFailure: VoiceTestFailure.voiceMissing,
        );
      await tester.pumpWidget(_app(
        tts: tts,
        voiceReply: FakeVoiceReplyPreferences(),
        voiceGateway: FakeTtsVoiceGateway(),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Probar voz'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.textContaining('voz del dispositivo'),
        findsOneWidget,
        reason: 'the user heard the robotic voice and must be told',
      );
    });

    testWidgets('each failure gets its OWN sentence, never one generic line', (tester) async {
      final messages = <VoiceTestFailure, String>{};

      for (final failure in [
        VoiceTestFailure.voiceMissing,
        VoiceTestFailure.synthesisFailed,
        VoiceTestFailure.noEngine,
      ]) {
        final tts = FakeTextToSpeechGateway()..nextOutcome = VoiceTestFailed(failure);
        await tester.pumpWidget(_app(
          tts: tts,
          voiceReply: FakeVoiceReplyPreferences(),
          voiceGateway: FakeTtsVoiceGateway(),
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Probar voz'));
        await tester.pumpAndSettle();

        final snack = tester.widget<SnackBar>(find.byType(SnackBar));
        messages[failure] = ((snack.content as Text).data)!;

        // Drop the tree so the next iteration starts from a clean screen.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }

      expect(
        messages.values.toSet(),
        hasLength(messages.length),
        reason: 'a refactor collapsed distinct causes back into one sentence: $messages',
      );
    });

    testWidgets('a missing neural voice offers the download right there', (tester) async {
      // The voice stays UNinstalled (the on-open download fails), which is the
      // only state in which "the neural voice is missing" is still true by the
      // time the user taps the offer.
      final voiceGateway = FakeTtsVoiceGateway(downloadError: StateError('sin red'));
      final tts = FakeTextToSpeechGateway()
        ..nextOutcome = const VoiceTestFailed(VoiceTestFailure.voiceMissing);
      await tester.pumpWidget(_app(
        tts: tts,
        voiceReply: FakeVoiceReplyPreferences(),
        voiceGateway: voiceGateway,
      ));
      await tester.pumpAndSettle();
      voiceGateway.downloadCalls.clear(); // the on-open proactive download

      await tester.tap(find.text('Probar voz'));
      await tester.pumpAndSettle();

      final action = find.widgetWithText(SnackBarAction, 'Descargar voz natural');
      expect(action, findsOneWidget);
      await tester.tap(action);
      await tester.pumpAndSettle();

      expect(voiceGateway.downloadCalls, isNotEmpty);
    });
  });

  testWidgets('opening the screen proactively downloads the neural voice, then shows it active',
      (tester) async {
    final voiceGateway = FakeTtsVoiceGateway(); // nothing installed yet
    await tester.pumpWidget(_app(
      tts: FakeTextToSpeechGateway(),
      voiceReply: FakeVoiceReplyPreferences(),
      voiceGateway: voiceGateway,
    ));
    await tester.pumpAndSettle();

    // The post-frame trigger kicked the neural-voice download (for the current
    // app language)…
    expect(voiceGateway.downloadCalls, isNotEmpty);
    // …and the card now reports the neural voice as active.
    expect(find.text('Voz natural activa'), findsOneWidget);
  });
}
