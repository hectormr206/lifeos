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

  /// BCP-47 tag of the voice's exact locale, e.g. `es-MX`, `en-GB`. Also the
  /// key the picker groups by (one accordion section per region).
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

/// One region (language + country) group in the accordion picker, e.g. every
/// `es-ES` voice. Preserves catalog order within the group.
class VoiceRegionGroup {
  const VoiceRegionGroup({
    required this.languageCode,
    required this.languageTag,
    required this.voices,
  });

  /// Base language code shared by every voice (`es` / `en`) — drives the
  /// language super-header (Español / Inglés).
  final String languageCode;

  /// Exact locale tag shared by every voice (`es-MX`, `en-GB`, …) — drives the
  /// country/region subheader and is the accordion section key.
  final String languageTag;

  /// The voices in this region, in catalog order.
  final List<VoiceDescriptor> voices;

  /// True when the group holds the currently-selected voice — the picker
  /// auto-expands exactly this one section.
  bool contains(String voiceId) => voices.any((v) => v.id == voiceId);
}

/// The immutable, hand-curated list of the hosted voices plus lookup and
/// grouping helpers. Pure data — no I/O — so it is trivially unit-testable.
class VoiceCatalog {
  const VoiceCatalog._();

  /// Sentinel selection meaning "no neural voice — use the device/system TTS".
  /// NOT a catalog voice ([contains] is false), so it never triggers a download
  /// and speak-time falls back to the system voice. Selected as the last-resort
  /// fallback after the user deletes their selected voice with no other voice
  /// installed, and persisted so the deletion sticks across launches.
  static const String systemVoiceId = 'system';

  /// All hosted voices, in display order (default voice first), grouped by
  /// region: Spanish (México, España, Argentina) then English (US, UK).
  ///
  /// Only voices whose Piper config is safe for the on-device sherpa-onnx
  /// engine are listed — `phoneme_type: espeak` AND single-speaker
  /// (`num_speakers <= 1`). Voices missing `phoneme_type` or that are
  /// multi-speaker crash sherpa NATIVELY (uncatchable from Dart) on synthesis,
  /// so they are deliberately excluded from the catalog (and a defensive
  /// pre-synthesis guard rejects any incompatible config that still reaches the
  /// engine — see `assertPiperVoiceCompatible`).
  static const List<VoiceDescriptor> all = [
    // ── Español · México ──────────────────────────────────────────────────
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
    // ── Español · España ──────────────────────────────────────────────────
    VoiceDescriptor(
      id: 'es_ES-davefx',
      displayName: 'Davefx (España)',
      languageTag: 'es-ES',
      languageLabel: 'Spanish (Spain)',
    ),
    // ── Español · Argentina ───────────────────────────────────────────────
    VoiceDescriptor(
      id: 'es_AR-daniela',
      displayName: 'Daniela (Argentina)',
      languageTag: 'es-AR',
      languageLabel: 'Spanish (Argentina)',
    ),
    // ── Inglés · Estados Unidos ───────────────────────────────────────────
    VoiceDescriptor(
      id: 'en_US-lessac',
      displayName: 'Lessac (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-amy',
      displayName: 'Amy (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-ljspeech',
      displayName: 'LJSpeech (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-kristin',
      displayName: 'Kristin (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-joe',
      displayName: 'Joe (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-john',
      displayName: 'John (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-hfc_female',
      displayName: 'HFC Female (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-hfc_male',
      displayName: 'HFC Male (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-bryce',
      displayName: 'Bryce (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-kusal',
      displayName: 'Kusal (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-mike',
      displayName: 'Mike (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-norman',
      displayName: 'Norman (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-reza_ibrahim',
      displayName: 'Reza Ibrahim (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    VoiceDescriptor(
      id: 'en_US-sam',
      displayName: 'Sam (US)',
      languageTag: 'en-US',
      languageLabel: 'English (US)',
    ),
    // ── Inglés · Reino Unido ──────────────────────────────────────────────
    VoiceDescriptor(
      id: 'en_GB-alan',
      displayName: 'Alan (UK)',
      languageTag: 'en-GB',
      languageLabel: 'English (UK)',
    ),
    VoiceDescriptor(
      id: 'en_GB-alba',
      displayName: 'Alba (UK)',
      languageTag: 'en-GB',
      languageLabel: 'English (UK)',
    ),
    VoiceDescriptor(
      id: 'en_GB-cori',
      displayName: 'Cori (UK)',
      languageTag: 'en-GB',
      languageLabel: 'English (UK)',
    ),
    VoiceDescriptor(
      id: 'en_GB-jenny_dioco',
      displayName: 'Jenny (UK)',
      languageTag: 'en-GB',
      languageLabel: 'English (UK)',
    ),
    VoiceDescriptor(
      id: 'en_GB-northern_english_male',
      displayName: 'Northern English (UK)',
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

  /// True when [id] is a known catalog voice (the system sentinel is NOT one).
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

  /// The voices grouped by region (exact locale tag), preserving catalog order:
  /// es-MX, es-ES, es-AR, en-US, en-GB. Drives the accordion sections.
  static List<VoiceRegionGroup> get groupedByRegion {
    final order = <String>[];
    final byTag = <String, List<VoiceDescriptor>>{};
    for (final voice in all) {
      if (!byTag.containsKey(voice.languageTag)) {
        order.add(voice.languageTag);
        byTag[voice.languageTag] = <VoiceDescriptor>[];
      }
      byTag[voice.languageTag]!.add(voice);
    }
    return [
      for (final tag in order)
        VoiceRegionGroup(
          languageCode: byTag[tag]!.first.languageCode,
          languageTag: tag,
          voices: byTag[tag]!,
        ),
    ];
  }
}
