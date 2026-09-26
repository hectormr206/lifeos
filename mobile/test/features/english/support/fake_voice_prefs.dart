// The saved voice choice, to prove English practice never changes it.
import 'package:lifeos/features/voice_settings/domain/selected_voice.dart';

class FakeVoicePrefs implements SelectedVoicePreferences {
  final List<String> saved = [];

  @override
  Future<String?> load() async => 'es_AR-daniela';

  @override
  Future<void> save(String voiceId) async => saved.add(voiceId);
}
