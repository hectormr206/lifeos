// Proves the "Voz" screen: the auto-speak switch reflects + sets the SHARED
// voice-reply preference, "Probar voz" speaks the sample through the shared
// gateway, and opening the screen proactively downloads the neural Piper voice
// so it becomes active. All engine/persistence seams are faked (no platform
// channels, no network).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
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
