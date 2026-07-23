/// The curated catalog of on-device Piper neural voices Axi can speak with.
///
/// Each voice is hosted on the VPS with the standard flat Piper layout
/// (`<id>.onnx` + `<id>.onnx.json`) under the same public `/tts/` base the
/// single-voice download already used — the id doubles as the remote file stem
/// (see `TtsVoiceSourceConfig.specForVoice`). Adding a voice = one more
/// [VoiceDescriptor] here plus its two hosted files; no other code changes.
class VoiceDescriptor {
  const VoiceDescriptor({
    required this.id,
    required this.displayName,
    required this.languageTag,
    required this.languageLabel,
    this.isDefault = false,
  });

  /// Stable voice id and remote file stem, e.g. `es_MX-claude` →
  /// `<baseUrl>/es_MX-claude.onnx`. Persisted as the user's selection.
  final String id;

  /// Human label shown in the picker (a proper voice name + region), e.g.
  /// "Claude (México)". Not translated — it is the voice's own name.
  final String displayName;

  /// BCP-47 tag of the voice's exact locale, e.g. `es-MX`, `en-GB`.
  final String languageTag;

  /// Catalog metadata label for the voice's language/region, e.g.
  /// "Spanish (Mexico)".
  final String languageLabel;

  /// True for the single shipped default (es_MX-claude) — used when the user
  /// has never chosen a voice.
  final bool isDefault;

  /// Remote/local model file name (`<id>.onnx`).
  String get modelFileName => '$id.onnx';

  /// Remote/local Piper config file name (`<id>.onnx.json`).
  String get configFileName => '$id.onnx.json';

  /// Base app-language code (`es` / `en`) derived from the id's locale prefix.
  /// Drives which language the preview sample sentence is spoken in.
  String get languageCode => id.split('_').first;
}

/// One language group in the picker (Spanish, then English), preserving the
/// catalog's declared order within each group.
class VoiceGroup {
  const VoiceGroup(this.languageCode, this.voices);

  /// Base language code shared by every voice in the group (`es` / `en`).
  final String languageCode;

  /// The voices in this group, in catalog order.
  final List<VoiceDescriptor> voices;
}

/// The immutable, hand-curated list of the six hosted voices plus lookup and
/// grouping helpers. Pure data — no I/O — so it is trivially unit-testable.
class VoiceCatalog {
  const VoiceCatalog._();

  /// All hosted voices, in display order (default voice first).
  static const List<VoiceDescriptor> all = [
    VoiceDescriptor(
      id: 'es_MX-claude',
      displayName: 'Claude (México)',
      languageTag: 'es-MX',
      languageLabel: 'Spanish (Mexico)',
      isDefault: true,
    ),
    VoiceDescriptor(
      id: 'es_MX-ald',
      displayName: 'Ald (México)',
      languageTag: 'es-MX',
      languageLabel: 'Spanish (Mexico)',
    ),
    VoiceDescriptor(
      id: 'es_AR-daniela',
      displayName: 'Daniela (Argentina)',
      languageTag: 'es-AR',
      languageLabel: 'Spanish (Argentina)',
    ),
    VoiceDescriptor(
      id: 'es_ES-davefx',
      displayName: 'Davefx (España)',
      languageTag: 'es-ES',
      languageLabel: 'Spanish (Spain)',
    ),
    VoiceDescriptor(
      id: 'en_US-lessac',
      displayName: 'Lessac (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_GB-alan',
      displayName: 'Alan (UK)',
      languageTag: 'en-GB',
      languageLabel: 'English (UK)',
    ),
  ];

  /// The shipped default voice (es_MX-claude) — used until the user picks one.
  static VoiceDescriptor get defaultVoice => all.firstWhere((v) => v.isDefault);

  /// The voice with [id], or null when [id] is not a known catalog voice.
  static VoiceDescriptor? byId(String id) {
    for (final voice in all) {
      if (voice.id == id) return voice;
    }
    return null;
  }

  /// True when [id] is a known catalog voice.
  static bool contains(String id) => byId(id) != null;

  /// The voices grouped by base language (Spanish group, then English),
  /// preserving catalog order within each group.
  static List<VoiceGroup> get groupedByLanguage {
    final order = <String>[];
    final byLanguage = <String, List<VoiceDescriptor>>{};
    for (final voice in all) {
      if (!byLanguage.containsKey(voice.languageCode)) {
        order.add(voice.languageCode);
        byLanguage[voice.languageCode] = <VoiceDescriptor>[];
      }
      byLanguage[voice.languageCode]!.add(voice);
    }
    return [for (final code in order) VoiceGroup(code, byLanguage[code]!)];
  }
}
