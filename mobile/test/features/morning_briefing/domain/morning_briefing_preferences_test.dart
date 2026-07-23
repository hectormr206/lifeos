// Proves SharedPrefsMorningBriefingPreferences seeds the default sources on
// first run, persists a custom source list, and round-trips the last briefing
// through JSON — using shared_preferences' in-memory mock (no platform channel).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_schedule.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('seeds default sources when nothing is stored', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsMorningBriefingPreferences();
    expect(await prefs.sources(), defaultBriefingSources);
  });

  test('persists and reads back a custom source list', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsMorningBriefingPreferences();

    await prefs.setSources(['https://a.com/rss', 'https://b.com/feed']);
    expect(await prefs.sources(), ['https://a.com/rss', 'https://b.com/feed']);
  });

  test('honors a deliberately empty source list', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsMorningBriefingPreferences();

    await prefs.setSources([]);
    expect(await prefs.sources(), isEmpty);
  });

  test('round-trips the last briefing through JSON', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsMorningBriefingPreferences();
    expect(await prefs.lastBriefing(), isNull);

    final briefing = OnDeviceBriefing(
      articles: const [
        BriefingArticle(
          sourceName: 'Fuente',
          title: 'Titular',
          url: 'https://x.com',
          description: 'Detalle',
        ),
      ],
      skippedSources: const ['Otra fuente'],
      generatedAt: DateTime(2026, 7, 20, 8, 30),
    );
    await prefs.saveLastBriefing(briefing);

    final loaded = await prefs.lastBriefing();
    expect(loaded, isNotNull);
    expect(loaded!.articles.single.sourceName, 'Fuente');
    expect(loaded.articles.single.title, 'Titular');
    expect(loaded.skippedSources, ['Otra fuente']);
    expect(loaded.generatedAt, DateTime(2026, 7, 20, 8, 30));
  });

  test('defaults the schedule to disabled at 8:00 when nothing is stored', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsMorningBriefingPreferences();
    expect(await prefs.schedule(), const BriefingSchedule(enabled: false, hour: 8, minute: 0));
  });

  test('round-trips the "Boletín automático" schedule', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsMorningBriefingPreferences();

    await prefs.saveSchedule(const BriefingSchedule(enabled: true, hour: 7, minute: 30));
    expect(await prefs.schedule(), const BriefingSchedule(enabled: true, hour: 7, minute: 30));

    // Disabling keeps the chosen hour for when it is re-enabled.
    await prefs.saveSchedule(const BriefingSchedule(enabled: false, hour: 7, minute: 30));
    expect(await prefs.schedule(), const BriefingSchedule(enabled: false, hour: 7, minute: 30));
  });

  test('decode returns null on malformed JSON', () {
    expect(OnDeviceBriefing.decode('not json'), isNull);
    expect(OnDeviceBriefing.decode('[1,2,3]'), isNull);
  });
}
