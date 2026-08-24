import 'dart:async';

import 'package:timezone/timezone.dart' as tz;

import '../../local_model/domain/local_llm_engine.dart';
import '../../local_model/domain/on_device_translator.dart';
import '../domain/briefing_assembler.dart';
import '../domain/briefing_background_work.dart';
import '../domain/briefing_brief_writer.dart';
import '../domain/briefing_harvester.dart';
import '../domain/briefing_notifications.dart';
import '../domain/briefing_schedule.dart';
import '../domain/briefing_scheduler.dart';
import '../domain/briefing_source.dart';
import '../domain/briefing_translation.dart';
import '../domain/morning_briefing.dart';
import '../domain/morning_briefing_preferences.dart';
import '../domain/section_digest_writer.dart';

/// Everything the headless background generation needs — a MINIMAL service
/// graph (no Riverpod, no UI providers), fully injectable so the runner body
/// is unit-testable on the host with fakes.
class BriefingBackgroundDeps {
  const BriefingBackgroundDeps({
    required this.preferences,
    required this.harvester,
    required this.assembler,
    required this.isModelAvailable,
    required this.engine,
    required this.notifications,
    required this.reminderScheduler,
    required this.backgroundWork,
    required this.now,
    required this.overrideLocation,
    required this.languageCode,
    this.timeout = defaultTimeout,
  });

  /// HARD overall timeout so a hung model load/inference can't burn battery
  /// for hours in the background — WorkManager's own 10-minute budget is the
  /// OS backstop; we bail out just under it and keep whatever was persisted.
  static const Duration defaultTimeout = Duration(minutes: 8);

  final MorningBriefingPreferences preferences;
  final BriefingHarvester harvester;
  final BriefingAssembler assembler;

  /// Whether the ~2.6GB model file is ALREADY on disk. When false the
  /// briefing is persisted with original (untranslated) text — the background
  /// task must NEVER trigger the model download.
  final Future<bool> Function() isModelAvailable;

  /// Engine used ONLY when [isModelAvailable] reports true. Null disables
  /// translation outright (composition roots without an engine).
  final LocalLlmEngine? engine;

  final BriefingNotifications notifications;
  final BriefingScheduler reminderScheduler;
  final BriefingBackgroundWork backgroundWork;

  /// Device-local "now" (injectable clock for tests).
  final DateTime Function() now;

  /// The manual-override [tz.Location] for schedule math, or `null` in
  /// AUTOMATIC mode (device-local). Mirrors the notifier's `_overrideLocation`.
  final Future<tz.Location?> Function() overrideLocation;

  /// The app output language ('es' / 'en') read from persistence.
  final Future<String> Function() languageCode;

  final Duration timeout;
}

/// Headless "Boletín automático" generation — the WorkManager task body.
///
/// Same rules as the in-app `maybeAutoGenerate`, but with NO process alive:
///   1. schedule guard: skip unless enabled + past today's slot + NOT already
///      generated today (the shared `BriefingSchedule.shouldRunNow` rule —
///      this is also what prevents DOUBLE generation: if the in-app timer ran
///      first this skips, and if this ran first the in-app guard skips);
///   2. fetch + assemble (network only, fast);
///   3. translate ONLY if the model file is already on disk (never download
///      2.6GB in background; on any model failure keep the originals);
///   4. persist + post the "Tu boletín está listo" notification (same
///      id/payload as the foreground path, so tapping opens the Boletín) and
///      remove the now-redundant "toca aquí" reminder;
///   5. re-arm reminder + next one-off work for the next slot (self-
///      perpetuating even when the app is never opened).
///
/// EVERY failure degrades gracefully (persist what we can / skip cleanly) and
/// the whole run sits under a hard [BriefingBackgroundDeps.timeout]. Always
/// returns `true` so WorkManager NEVER retry-loops a failed generation — the
/// reminder + generate-on-open fallback is the recovery path.
Future<bool> runMorningBriefingBackgroundTask(
  BriefingBackgroundDeps deps,
) async {
  try {
    await _run(deps).timeout(deps.timeout);
  } catch (_) {
    // No network / model OOM / timeout / anything: clean skip. Still try to
    // re-arm so tomorrow's run exists even after a bad day.
    await _rearmSafely(deps);
  }
  return true;
}

Future<void> _run(BriefingBackgroundDeps deps) async {
  final schedule = await deps.preferences.schedule();
  final location = await _locationSafely(deps);
  final base = deps.now();
  final nowInZone = location == null
      ? base
      : tz.TZDateTime.from(base, location);
  final last = await _lastBriefingSafely(deps);

  final due = schedule.shouldRunNow(
    nowInZone,
    lastGeneratedAt: last?.generatedAt,
    location: location,
  );
  if (!due) {
    // Disabled / fired early / already generated today (e.g. the in-app path
    // beat us to it) — nothing to do beyond keeping the chain armed.
    await _rearm(deps, schedule, location, lastGeneratedAt: last?.generatedAt);
    return;
  }

  final sources = await deps.preferences.sources();
  // The harvester fetches URLs; the section is what the user reads them under.
  // Only the ENABLED ones: a source turned off must not keep being fetched in
  // the background, or "desactivada" means nothing.
  final harvests = await deps.harvester.harvestAll(
    enabledBriefingSources(sources),
  );
  final assembled = deps.assembler.assemble(
    harvests,
    now: base,
    generatedAt: base,
  );
  if (assembled.isEmpty) {
    // No fresh news: skip cleanly (the foreground path will report the empty
    // state if the user opens the app); keep the chain armed for tomorrow.
    await _rearm(deps, schedule, location, lastGeneratedAt: last?.generatedAt);
    return;
  }

  var briefing = assembled;
  final engine = deps.engine;
  if (engine != null && await _modelAvailableSafely(deps)) {
    // HEAVY + INTENTIONAL: loading the ~2.6GB model headless is the cost the
    // user accepted for a ready-made briefing. The pipeline never throws
    // (per-source isolation; catastrophic failure keeps originals), and the
    // engine is released right after so the background process frees the RAM.
    try {
      final pipeline = BriefingTranslationPipeline(
        translator: OnDeviceTranslator(engine),
        extractor: deps.harvester.extractor,
      );
      briefing = await pipeline.translateAll(
        assembled,
        languageCode: await deps.languageCode(),
      );
      // Then write the briefs the feeds never carried, while the model is
      // still loaded. Both stages finish BEFORE the notification below, so
      // "tu boletín está listo" is only ever said about a finished briefing —
      // translated, and with every card carrying text.
      briefing = await BriefingBriefWriter(
        engine: engine,
        fetcher: deps.harvester.fetcher,
        extractor: deps.harvester.extractor,
      ).fillMissing(briefing);
      // Last stage, with the model still warm: one paragraph per section, so
      // the reader can decide what to open without reading every card.
      briefing = await BriefingSectionDigestWriter(
        engine: engine,
      ).fillDigests(briefing);
    } catch (_) {
      briefing = assembled; // keep originals — never lose the fetched news
    } finally {
      try {
        await engine.dispose();
      } catch (_) {
        /* best-effort release */
      }
    }
  }

  // Stamped at the END: the visible date has to say when the briefing was
  // ready, not when the task woke up.
  briefing = briefing.stampedAt(deps.now());

  await deps.preferences.saveLastBriefing(briefing);

  // The "toca aquí y genera" reminder (fired at the same hour) is now
  // redundant — remove it from the shade before announcing the result.
  try {
    await deps.reminderScheduler.cancelReminder();
  } catch (_) {
    /* best-effort */
  }
  try {
    await deps.notifications.showBriefingReady();
  } catch (_) {
    /* the briefing is persisted either way */
  }

  await _rearm(deps, schedule, location, lastGeneratedAt: briefing.generatedAt);
}

/// Re-arms BOTH next-slot triggers (reminder alarm + one-off work) from the
/// background, mirroring the notifier's `_armTriggers`, so the daily chain
/// survives indefinitely without the app ever being opened.
Future<void> _rearm(
  BriefingBackgroundDeps deps,
  BriefingSchedule schedule,
  tz.Location? location, {
  DateTime? lastGeneratedAt,
}) async {
  if (!schedule.enabled) {
    await deps.backgroundWork.cancel();
    await deps.reminderScheduler.cancelReminder();
    return;
  }
  final base = deps.now();
  final nowInZone = location == null
      ? base
      : tz.TZDateTime.from(base, location);
  final next = schedule.nextRun(
    nowInZone,
    lastGeneratedAt: lastGeneratedAt,
    location: location,
  );
  await deps.reminderScheduler.scheduleReminder(
    next.add(kBriefingReminderGrace),
  );
  // Arm the WORK at the start instant and the REMINDER at the promised hour:
  // the generation needs a head start to be finished when the reader looks.
  await deps.backgroundWork.scheduleOneOff(
    next.subtract(BriefingSchedule.lead).difference(base),
  );
}

Future<void> _rearmSafely(BriefingBackgroundDeps deps) async {
  try {
    final schedule = await deps.preferences.schedule();
    final location = await _locationSafely(deps);
    final last = await _lastBriefingSafely(deps);
    await _rearm(deps, schedule, location, lastGeneratedAt: last?.generatedAt);
  } catch (_) {
    // Even re-arming failed — the OS reminder scheduled by the last app run
    // (or the next app open) remains the floor. Never crash the worker.
  }
}

Future<tz.Location?> _locationSafely(BriefingBackgroundDeps deps) async {
  try {
    return await deps.overrideLocation();
  } catch (_) {
    return null; // degrade to device-local, exactly like the notifier
  }
}

Future<OnDeviceBriefing?> _lastBriefingSafely(
  BriefingBackgroundDeps deps,
) async {
  try {
    return await deps.preferences.lastBriefing();
  } catch (_) {
    return null;
  }
}

Future<bool> _modelAvailableSafely(BriefingBackgroundDeps deps) async {
  try {
    return await deps.isModelAvailable();
  } catch (_) {
    return false; // unknown → originals; NEVER risk a download/load
  }
}
