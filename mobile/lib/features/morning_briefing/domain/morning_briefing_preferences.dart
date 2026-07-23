import 'package:shared_preferences/shared_preferences.dart';

import 'morning_briefing.dart';

/// Sensible starting news sources (RSS feeds) the user can change or remove.
/// Kept feed-first because the pipeline extracts feeds most reliably.
const List<String> defaultBriefingSources = [
  'https://www.eldiario.es/rss/',
  'https://feeds.bbci.co.uk/mundo/rss.xml',
];

/// Local-only persistence for the ON-DEVICE morning briefing: the user's list
/// of news-source URLs plus the last briefing the model produced (so it
/// survives navigation + relaunch).
///
/// Same rationale/shape as [AppUpdatePreferences] / [LocalModelPreferences]:
/// deliberately `shared_preferences` (non-secret UI state, must survive with no
/// engine/pairing) and abstract so notifiers depend on the interface and tests
/// inject a fake without the platform channel.
abstract class MorningBriefingPreferences {
  /// The configured news-source URLs (seeded with [defaultBriefingSources] the
  /// first time, before the user has customized anything).
  Future<List<String>> sources();

  Future<void> setSources(List<String> urls);

  /// The last briefing the on-device pipeline produced, or null if never run.
  Future<OnDeviceBriefing?> lastBriefing();

  Future<void> saveLastBriefing(OnDeviceBriefing briefing);
}

/// [MorningBriefingPreferences] backed by `shared_preferences`.
class SharedPrefsMorningBriefingPreferences implements MorningBriefingPreferences {
  SharedPrefsMorningBriefingPreferences({SharedPreferences? prefs}) : _prefs = prefs; // ignore: prefer_initializing_formals

  static const String sourcesKey = 'morning_briefing_sources';
  static const String lastBriefingKey = 'morning_briefing_last';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<List<String>> sources() async {
    final p = await _instance;
    // Absent key (first run) → seed with defaults; an empty list the user
    // deliberately saved is honored as empty.
    return p.getStringList(sourcesKey) ?? List<String>.from(defaultBriefingSources);
  }

  @override
  Future<void> setSources(List<String> urls) async => (await _instance).setStringList(sourcesKey, urls);

  @override
  Future<OnDeviceBriefing?> lastBriefing() async {
    final raw = (await _instance).getString(lastBriefingKey);
    if (raw == null) return null;
    return OnDeviceBriefing.decode(raw);
  }

  @override
  Future<void> saveLastBriefing(OnDeviceBriefing briefing) async =>
      (await _instance).setString(lastBriefingKey, briefing.encode());
}
