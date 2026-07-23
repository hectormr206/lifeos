// GOLDEN: the voice-catalog picker — 6 Piper voices grouped by language
// (Spanish, then English). One voice is installed + selected (es_MX-claude),
// one is mid-download (es_MX-ald at 45%), the rest are not installed. Status is
// injected via fixed notifiers so there is no gateway probe, no download, and no
// indeterminate spinner (progress is a fixed value → the PNG is stable).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/features/voice_settings/presentation/voice_catalog_providers.dart';
import 'package:lifeos/features/voice_settings/presentation/voice_catalog_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import 'support/golden_harness.dart';

/// Selected voice pinned to a fixed id — no async hydration from prefs.
class _FixedSelectedVoice extends SelectedVoiceNotifier {
  _FixedSelectedVoice(this._id);
  final String _id;
  @override
  String build() => _id;
}

/// Whole-catalog install status pinned to a fixed map — no gateway probe.
class _FixedCatalog extends VoiceCatalogController {
  _FixedCatalog(this._fixed);
  final Map<String, TtsVoiceStatus> _fixed;
  @override
  Map<String, TtsVoiceStatus> build() => _fixed;
}

void main() {
  testWidgets('golden: voice catalog — installed/selected, downloading, absent',
      (tester) async {
    useGoldenSurface(tester);

    const statuses = <String, TtsVoiceStatus>{
      'es_MX-claude': TtsVoiceReady(), // installed + selected
      'es_MX-ald': TtsVoiceDownloading(0.45), // mid-download
      'es_AR-daniela': TtsVoiceAbsent(),
      'es_ES-davefx': TtsVoiceAbsent(),
      'en_US-lessac': TtsVoiceAbsent(),
      'en_GB-alan': TtsVoiceAbsent(),
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedVoiceProvider
              .overrideWith(() => _FixedSelectedVoice('es_MX-claude')),
          voiceCatalogControllerProvider
              .overrideWith(() => _FixedCatalog(statuses)),
        ],
        child: MaterialApp(
          theme: goldenTheme(),
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const VoiceCatalogScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(VoiceCatalogScreen),
      matchesGoldenFile('images/voice_catalog_screen.png'),
    );
  });
}
