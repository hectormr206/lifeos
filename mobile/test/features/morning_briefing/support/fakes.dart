import 'package:lifeos/features/morning_briefing/domain/briefing_notifications.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing_preferences.dart';
import 'package:lifeos/features/morning_briefing/domain/source_fetcher.dart';

/// In-memory [SourceFetcher]: returns a canned body per URL, or throws for URLs
/// listed in [failing] so the per-source skip path is testable. No network.
class FakeSourceFetcher implements SourceFetcher {
  FakeSourceFetcher({Map<String, String>? bodies, Set<String>? failing})
      : bodies = bodies ?? const {},
        failing = failing ?? const {};

  final Map<String, String> bodies;
  final Set<String> failing;
  final List<String> fetched = [];

  @override
  Future<String> fetch(String url) async {
    fetched.add(url);
    if (failing.contains(url)) throw Exception('boom $url');
    final body = bodies[url];
    if (body == null) throw Exception('no body for $url');
    return body;
  }
}

/// In-memory [BriefingNotifications]: counts posts + stores the tap handler. No
/// flutter_local_notifications channel.
class FakeBriefingNotifications implements BriefingNotifications {
  int shown = 0;
  void Function()? handler;
  bool launched = false;

  @override
  Future<void> showBriefingReady() async => shown++;

  @override
  Future<void> registerTapHandler(void Function() onTapBriefing) async => handler = onTapBriefing;

  @override
  Future<bool> launchedByTap() async => launched;
}

/// In-memory [MorningBriefingPreferences]: no shared_preferences channel.
class FakeMorningBriefingPreferences implements MorningBriefingPreferences {
  FakeMorningBriefingPreferences({List<String>? initialSources, OnDeviceBriefing? initialBriefing})
      : _sources = initialSources ?? const [],
        _lastBriefing = initialBriefing;

  List<String> _sources;
  OnDeviceBriefing? _lastBriefing;
  int saveCount = 0;
  int setSourcesCount = 0;

  @override
  Future<List<String>> sources() async => List<String>.from(_sources);

  @override
  Future<void> setSources(List<String> urls) async {
    _sources = List<String>.from(urls);
    setSourcesCount++;
  }

  @override
  Future<OnDeviceBriefing?> lastBriefing() async => _lastBriefing;

  @override
  Future<void> saveLastBriefing(OnDeviceBriefing briefing) async {
    _lastBriefing = briefing;
    saveCount++;
  }
}
