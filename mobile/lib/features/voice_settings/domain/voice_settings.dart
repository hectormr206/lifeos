import 'package:shared_preferences/shared_preferences.dart';

/// The user's persisted "Voz" (speak-aloud) tuning — a deliberately TINY set of
/// knobs so Axi sounds great with ZERO configuration. Today it is a single
/// user-facing [rate] plus a curated default [pitch] we ship (no pitch UI); the
/// values apply to BOTH speak engines (neural Piper and the system fallback).
///
/// [rate] / [pitch] are normalized MULTIPLIERS around 1.0 (normal):
///  * 1.0 = the shipped, tuned-for-Piper default (natural es_MX pace).
///  * < 1.0 slower / lower, > 1.0 faster / higher.
///
/// Each engine has its own native scale, so the multipliers are mapped per
/// engine ([piperSpeed], [systemRate], [systemPitch]) rather than leaking a
/// device-specific number into the UI.
class VoiceSettings {
  const VoiceSettings({
    this.rate = defaultRate,
    this.pitch = defaultPitch,
  });

  /// Shipped default speech rate — tuned so the neural Piper es_MX voice reads
  /// at a natural, unhurried narration pace out of the box.
  static const double defaultRate = 1.0;

  /// Shipped default pitch — neutral. Kept as a curated constant (no slider in
  /// the minimal UI); only the system fallback voice honors pitch (VITS/Piper
  /// has no pitch control), so this mostly future-proofs the model.
  static const double defaultPitch = 1.0;

  /// Bounds for the user-facing rate slider (slow ↔ fast).
  static const double minRate = 0.5;
  static const double maxRate = 2.0;

  /// A normalized multiplier: 1.0 = normal narration pace. Clamped to
  /// [minRate]..[maxRate].
  final double rate;

  /// A normalized pitch multiplier: 1.0 = neutral. No UI today; ships at
  /// [defaultPitch].
  final double pitch;

  /// Piper (sherpa-onnx VITS) `speed` argument: its native scale already is a
  /// multiplier where 1.0 is normal, so [rate] maps straight through.
  double get piperSpeed => rate.clamp(minRate, maxRate);

  /// `flutter_tts` speech rate (0.0..1.0). The interim engine reads naturally at
  /// ~0.5, so the normalized [rate] scales around that anchor and is clamped to
  /// the plugin's valid range.
  double get systemRate => (0.5 * rate).clamp(0.1, 1.0);

  /// `flutter_tts` pitch (0.5..2.0, 1.0 neutral). The multiplier maps straight
  /// through, clamped to the plugin's valid range.
  double get systemPitch => pitch.clamp(0.5, 2.0);

  VoiceSettings copyWith({double? rate, double? pitch}) => VoiceSettings(
        rate: rate ?? this.rate,
        pitch: pitch ?? this.pitch,
      );

  @override
  bool operator ==(Object other) =>
      other is VoiceSettings && other.rate == rate && other.pitch == pitch;

  @override
  int get hashCode => Object.hash(rate, pitch);

  @override
  String toString() => 'VoiceSettings(rate: $rate, pitch: $pitch)';
}

/// Local-only persistence for [VoiceSettings].
///
/// Deliberately NOT `flutter_secure_storage`: rate/pitch are non-secret UI
/// preferences that MUST survive with no engine connection / no pairing
/// (mirrors [VoiceReplyPreferences] / [WebSearchPreferences]). Abstracted so the
/// notifier depends on the interface and tests inject a fake without the
/// platform channel.
abstract class VoiceSettingsPreferences {
  /// The persisted settings; defaults ([VoiceSettings.defaultRate],
  /// [VoiceSettings.defaultPitch]) when never set.
  Future<VoiceSettings> load();

  /// Persists [settings].
  Future<void> save(VoiceSettings settings);
}

/// [VoiceSettingsPreferences] backed by `shared_preferences`.
class SharedPrefsVoiceSettingsPreferences implements VoiceSettingsPreferences {
  SharedPrefsVoiceSettingsPreferences({SharedPreferences? prefs}) : _prefs = prefs; // ignore: prefer_initializing_formals

  static const String rateKey = 'voice_speech_rate';
  static const String pitchKey = 'voice_pitch';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<VoiceSettings> load() async {
    final prefs = await _instance;
    return VoiceSettings(
      rate: prefs.getDouble(rateKey) ?? VoiceSettings.defaultRate,
      pitch: prefs.getDouble(pitchKey) ?? VoiceSettings.defaultPitch,
    );
  }

  @override
  Future<void> save(VoiceSettings settings) async {
    final prefs = await _instance;
    await prefs.setDouble(rateKey, settings.rate);
    await prefs.setDouble(pitchKey, settings.pitch);
  }
}
