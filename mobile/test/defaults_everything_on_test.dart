// Proves the STANDING RULE "everything ON by default": the morning briefing
// auto-schedule, the voice-reply auto-speak, and the daily digest all default
// ENABLED (value objects + never-set SharedPreferences), while the per-message
// web-search chat toggle deliberately STAYS OFF (a costly per-turn opt-in).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/voice_reply_preferences.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_preferences.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_schedule.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_schedule.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('value objects default ON', () {
    test('morning briefing schedule defaults enabled', () {
      expect(const BriefingSchedule().enabled, isTrue);
    });
    test('daily digest schedule defaults enabled at 21:00', () {
      const s = DailyDigestSchedule();
      expect(s.enabled, isTrue);
      expect(s.hour, 21);
    });
  });

  group('never-set preferences default ON', () {
    test('morning briefing prefs schedule enabled', () async {
      final prefs = SharedPrefsMorningBriefingPreferences();
      expect((await prefs.schedule()).enabled, isTrue);
    });
    test('daily digest prefs schedule enabled + default instructions', () async {
      final prefs = SharedPrefsDailyDigestPreferences();
      expect((await prefs.schedule()).enabled, isTrue);
      expect(await prefs.instructions(), kDefaultDigestInstructions);
    });
    test('voice-reply auto-speak enabled', () async {
      expect(await SharedPrefsVoiceReplyPreferences().isEnabled(), isTrue);
    });
  });

  group('providers', () {
    test('voice-reply reaches ON after hydration (effective default)', () async {
      // The notifier starts at a safe false and hydrates to the persisted value,
      // which defaults to true (never-set preference) — the everything-on default.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(voiceReplyEnabledProvider.notifier).ready;
      expect(container.read(voiceReplyEnabledProvider), isTrue);
    });

    test('web-search per-message toggle STAYS OFF by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(webSearchEnabledProvider), isFalse);
    });
  });
}
