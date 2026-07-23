import 'package:shared_preferences/shared_preferences.dart';

import 'morning_briefing.dart';

/// Starting news sources (RSS/Atom feeds), seeded from the laptop LifeOS
/// briefing config (axi/src/axi/briefing.py). The user can change or remove
/// them. Kept feed-first because the pipeline extracts feeds most reliably;
/// the laptop's Hacker News source is omitted (it uses a special HN-Algolia
/// adapter the on-device pipeline doesn't have yet).
///
/// NOTE for distribution: curate a GLOBAL default set later — several of these
/// are ES/MX-specific and new users (e.g. shared installs) may be elsewhere.
const List<String> defaultBriefingSources = [
  // General / world (Spanish)
  'https://feeds.bbci.co.uk/mundo/rss.xml',
  // Mexico
  'https://expansion.mx/rss',
  // AI (English)
  'https://simonwillison.net/atom/everything/',
  'https://huggingface.co/blog/feed.xml',
  // Linux (Spanish)
  'https://www.muylinux.com/feed/',
  'https://soploslinux.com/feed/',
  'https://www.linuxadictos.com/feed/',
  'https://blog.desdelinux.net/feed/',
  'https://www.xn--linuxenespaol-skb.com/feed/',
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
