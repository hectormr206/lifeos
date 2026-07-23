import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/daily_digest.dart';
import '../domain/daily_digest_schedule.dart';
import 'daily_digest_providers.dart';

/// Where the digest pipeline currently is, for the UI progress state.
enum DailyDigestPhase { idle, generating, done, error }

/// Immutable UI state for the on-device daily digest.
class DailyDigestState {
  const DailyDigestState({
    this.schedule = const DailyDigestSchedule(),
    this.digest,
    this.phase = DailyDigestPhase.idle,
    this.error,
  });

  /// The schedule (ENABLED + 21:00 by default — everything-on rule).
  final DailyDigestSchedule schedule;

  /// The last digest produced (persisted so it survives navigation).
  final DailyDigest? digest;

  final DailyDigestPhase phase;

  /// Neutral-Spanish failure message (only when [phase] is error).
  final String? error;

  bool get isGenerating => phase == DailyDigestPhase.generating;

  DailyDigestState copyWith({
    DailyDigestSchedule? schedule,
    DailyDigest? digest,
    DailyDigestPhase? phase,
    String? error,
  }) =>
      DailyDigestState(
        schedule: schedule ?? this.schedule,
        digest: digest ?? this.digest,
        phase: phase ?? this.phase,
        error: error,
      );
}

/// Runs the ON-DEVICE daily-digest pipeline and owns its UI state, scheduling,
/// and persistence. Mirrors [MorningBriefingNotifier]'s scheduled-autonomous-run
/// shape (OS reminder + in-app timer, one-shot + rearm).
///
/// The digest is a BUILT-IN: the user may only change the send TIME,
/// ACTIVATE/DEACTIVATE it, and trigger a run ("generar ahora"). It is never
/// DELETED — there is no delete method here. The narration instruction is a
/// fixed internal constant and is not exposed or editable.
class DailyDigestNotifier extends Notifier<DailyDigestState> {
  Future<void>? _bootstrapFuture;
  Timer? _autoRunTimer;

  /// Injectable clock for schedule math AND the aggregation "today" window
  /// (production uses the device clock; tests inject a fixed one).
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// Lets tests await the initial hydration deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  DailyDigestState build() {
    ref.onDispose(() => _autoRunTimer?.cancel());
    _bootstrapFuture = _hydrate();
    return const DailyDigestState();
  }

  Future<void> _hydrate() async {
    try {
      final prefs = ref.read(dailyDigestPreferencesProvider);
      final schedule = await prefs.schedule();
      final last = await prefs.lastDigest();
      state = state.copyWith(schedule: schedule, digest: last);
    } catch (_) {
      // Persistence unavailable (no platform channel in a widget test) — keep
      // the safe defaults (schedule ON).
    }
    await _armTriggers();
  }

  // ── Schedule (edit time / deactivate; never delete) ────────────────────────

  Future<void> setScheduleEnabled(bool enabled) =>
      _updateSchedule(state.schedule.copyWith(enabled: enabled));

  Future<void> setScheduleTime(int hour, int minute) =>
      _updateSchedule(state.schedule.copyWith(hour: hour, minute: minute));

  Future<void> _updateSchedule(DailyDigestSchedule schedule) async {
    state = state.copyWith(schedule: schedule);
    try {
      await ref.read(dailyDigestPreferencesProvider).saveSchedule(schedule);
    } catch (_) {
      // Best-effort persistence; in-memory state still reflects the choice.
    }
    await _armTriggers();
  }

  // ── Triggers (OS reminder + in-app timer) ──────────────────────────────────

  Future<void> _armTriggers() async {
    _autoRunTimer?.cancel();
    _autoRunTimer = null;
    final scheduler = ref.read(dailyDigestSchedulerProvider);
    final schedule = state.schedule;
    if (!schedule.enabled) {
      await scheduler.cancelReminder();
      return;
    }
    final now = clock();
    final next = schedule.nextRun(now, lastGeneratedAt: state.digest?.generatedAt);
    await scheduler.scheduleReminder(next);
    _autoRunTimer = Timer(next.difference(now), () => maybeAutoGenerate());
  }

  /// Entry point for every trigger path: runs [generate] IF a run is due AND
  /// today's digest does not exist yet. Always re-arms after.
  Future<void> maybeAutoGenerate() async {
    await ready;
    if (state.isGenerating) return;
    final due = state.schedule.shouldRunNow(
      clock(),
      lastGeneratedAt: state.digest?.generatedAt,
    );
    if (due) {
      await ref.read(dailyDigestSchedulerProvider).cancelReminder();
      await generate();
    }
    await _armTriggers();
  }

  // ── Generation ──────────────────────────────────────────────────────────────

  /// Runs the pipeline: aggregate today's local data → model wrap-up → persist
  /// → notify. No-op while already generating.
  Future<void> generate() async {
    if (state.isGenerating) return;
    state = state.copyWith(phase: DailyDigestPhase.generating, error: null);
    try {
      final service = await ref.read(dailyDigestServiceProvider.future);
      final digest = await service.generate(now: clock());
      state = state.copyWith(digest: digest, phase: DailyDigestPhase.done);
      try {
        await ref.read(dailyDigestPreferencesProvider).saveLastDigest(digest);
      } catch (_) {
        // In-memory digest still shown even if persistence failed.
      }
      // Only nudge when there was actually something to summarize.
      if (!digest.isEmpty) {
        try {
          await ref.read(dailyDigestNotificationsProvider).showDigestReady();
        } catch (_) {
          // Notification is best-effort; the digest is already on screen.
        }
      }
    } catch (_) {
      state = state.copyWith(
        phase: DailyDigestPhase.error,
        error: 'No se pudo preparar el resumen de hoy. Inténtalo de nuevo.',
      );
    }
    try {
      await _armTriggers();
    } catch (_) {
      // Scheduling is best-effort; the run itself already finished.
    }
  }
}

final dailyDigestNotifierProvider =
    NotifierProvider<DailyDigestNotifier, DailyDigestState>(DailyDigestNotifier.new);
