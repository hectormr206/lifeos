import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/timezone/effective_timezone.dart';
import '../../../core/timezone/timezone_providers.dart';
import '../../../core/timezone/timezone_preference.dart';
import '../../daily_digest/presentation/daily_digest_notifier.dart';
import '../../morning_briefing/presentation/morning_briefing_notifier.dart';

/// UI state for the "Zona horaria" settings screen.
class TimezoneSettingsState {
  const TimezoneSettingsState({
    this.preference = const TimezonePreference.automatic(),
    this.detectedZoneId,
    this.loading = true,
  });

  /// The persisted choice (AUTOMATIC or a pinned IANA id).
  final TimezonePreference preference;

  /// The device's detected IANA id, for the read-only "Detectada: …" line.
  final String? detectedZoneId;

  /// True until the first hydration completes.
  final bool loading;

  bool get isAutomatic => preference.isAutomatic;

  /// The id shown as the current override selection (empty in AUTOMATIC mode).
  String get overrideZoneId => preference.overrideZoneId ?? '';

  TimezoneSettingsState copyWith({
    TimezonePreference? preference,
    String? detectedZoneId,
    bool? loading,
  }) =>
      TimezoneSettingsState(
        preference: preference ?? this.preference,
        detectedZoneId: detectedZoneId ?? this.detectedZoneId,
        loading: loading ?? this.loading,
      );
}

/// Owns the timezone preference (AUTOMATIC vs manual override) and, on every
/// change, RE-ARMS the schedules that depend on the effective zone so the new
/// choice takes effect without a manual re-save:
///   * invalidates [effectiveTimezoneProvider] so the next read reflects it,
///   * re-arms the daily digest + morning briefing (their `maybeAutoGenerate`
///     re-computes the next run in the new zone).
///
/// Reminders re-arm on their next edit / on the reminders screen load (their
/// alarms are re-scheduled through the same effective-zone resolver then).
class TimezoneSettingsNotifier extends Notifier<TimezoneSettingsState> {
  Future<void>? _bootstrapFuture;

  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  TimezoneSettingsState build() {
    _bootstrapFuture = _hydrate();
    return const TimezoneSettingsState();
  }

  Future<void> _hydrate() async {
    var preference = const TimezonePreference.automatic();
    String? detected;
    try {
      preference = await ref.read(timezonePreferencesProvider).load();
    } catch (_) {
      // No platform channel (widget test) — keep AUTOMATIC.
    }
    try {
      detected = await ref.read(deviceTimezoneDetectorProvider).currentZoneId();
    } catch (_) {
      // Detection unavailable — leave the "Detectada" line blank.
    }
    state = state.copyWith(preference: preference, detectedZoneId: detected, loading: false);
  }

  /// All IANA zone ids for the override picker (sorted).
  List<String> availableZoneIds() => EffectiveTimezoneResolver.availableZoneIds();

  /// Follow the device zone (default).
  Future<void> setAutomatic() => _apply(const TimezonePreference.automatic());

  /// Pin [zoneId] as a manual override.
  Future<void> setOverride(String zoneId) => _apply(TimezonePreference.override(zoneId));

  Future<void> _apply(TimezonePreference preference) async {
    state = state.copyWith(preference: preference);
    try {
      await ref.read(timezonePreferencesProvider).save(preference);
    } catch (_) {
      // Best-effort persistence; in-memory state still reflects the choice.
    }
    // Re-read the effective zone next time, then re-arm the zone-dependent
    // schedules so the change lands without needing a manual re-save.
    ref.invalidate(effectiveTimezoneProvider);
    try {
      await ref.read(dailyDigestNotifierProvider.notifier).maybeAutoGenerate();
    } catch (_) {
      // Best-effort re-arm.
    }
    try {
      await ref.read(morningBriefingNotifierProvider.notifier).maybeAutoGenerate();
    } catch (_) {
      // Best-effort re-arm.
    }
  }
}

final timezoneSettingsNotifierProvider =
    NotifierProvider<TimezoneSettingsNotifier, TimezoneSettingsState>(
        TimezoneSettingsNotifier.new);

/// Case-insensitive substring filter for the override picker. Pure + top-level
/// so both the screen and its widget test share the exact same matching.
List<String> filterZoneIds(List<String> ids, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return ids;
  return ids.where((id) => id.toLowerCase().contains(q)).toList();
}
