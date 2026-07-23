// Proves the accordion voice picker: region sections are COLLAPSED by default
// except the one holding the selected voice (auto-expanded), and a downloaded
// voice exposes a delete affordance that runs the confirm → delete flow.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/features/tts/presentation/tts_providers.dart';
import 'package:lifeos/features/voice_settings/domain/selected_voice.dart';
import 'package:lifeos/features/voice_settings/presentation/voice_catalog_providers.dart';
import 'package:lifeos/features/voice_settings/presentation/voice_catalog_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../tts/support/fake_tts.dart';

const fakeVoicePaths = TtsVoicePaths(model: 'm.onnx', tokens: 'm.tokens.txt', dataDir: 'espeak');

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

Widget _app({
  required String selectedId,
  required Map<String, TtsVoiceStatus> statuses,
  FakeTtsVoiceGateway? gateway,
  bool realController = false,
}) {
  return ProviderScope(
    overrides: [
      if (gateway != null) ttsVoiceGatewayProvider.overrideWithValue(gateway),
      selectedVoiceProvider.overrideWith(() => _FixedSelectedVoice(selectedId)),
      if (!realController)
        voiceCatalogControllerProvider.overrideWith(() => _FixedCatalog(statuses)),
    ],
    child: MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const VoiceCatalogScreen(),
    ),
  );
}

void main() {
  testWidgets('auto-expands ONLY the region holding the selected voice', (tester) async {
    await tester.pumpWidget(_app(
      selectedId: 'es_ES-davefx',
      statuses: const {'es_ES-davefx': TtsVoiceReady()},
    ));
    await tester.pumpAndSettle();

    // Region titles are always rendered (collapsed tiles show their header).
    expect(find.text('España'), findsOneWidget);
    expect(find.text('México'), findsOneWidget);

    // The selected voice's section is expanded → its voice is visible.
    expect(find.text('Davefx (España)'), findsOneWidget);
    // A voice in another (collapsed) region is NOT rendered.
    expect(find.text('Claude (México)'), findsNothing);
    expect(find.text('Lessac (US)'), findsNothing);
  });

  testWidgets('deleting a downloaded voice runs the confirm dialog then deletes', (tester) async {
    final gateway = FakeTtsVoiceGateway(installed: {'es_MX-claude': fakeVoicePaths});
    await tester.pumpWidget(_app(
      selectedId: 'es_MX-claude',
      statuses: const {'es_MX-claude': TtsVoiceReady()},
      gateway: gateway,
      realController: true,
    ));
    await tester.pumpAndSettle();

    // The selected (downloaded) voice shows a delete affordance.
    final deleteButton = find.byIcon(Icons.delete_outline);
    expect(deleteButton, findsOneWidget);

    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    // Confirm dialog appears; confirm the deletion.
    expect(find.text('¿Eliminar esta voz?'), findsOneWidget);
    await tester.tap(find.text('Eliminar').last);
    await tester.pumpAndSettle();

    expect(gateway.deleteCalls, contains('es_MX-claude'));
  });
}
