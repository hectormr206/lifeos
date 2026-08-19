import 'package:timezone/timezone.dart' as tz;

import '../../../core/graph/local_graph_store.dart';
import '../../domains/data/local_domain_repository.dart';
import '../../domains/domain/domain_descriptor.dart';
import '../../domains/domain/local_domain_entry.dart';
import '../../domains/domain/local_entry_config.dart';
import '../../local_model/domain/local_llm_engine.dart';
import '../../memory/domain/person_directory.dart';
import '../domain/daily_digest.dart';
import '../domain/daily_digest_aggregator.dart';
import '../domain/cross_domain_patterns.dart';
import '../domain/digest_insights.dart';

/// FIXED, internal narration instruction that shapes the on-device model's
/// natural-language wrap-up over the deterministically-assembled facts.
///
/// This is a PRODUCT-OWNED constant: it is NOT user-editable, NOT surfaced in
/// the UI, and NOT read from or written to preferences. The digest still needs
/// a narration instruction for the model, so it lives here and is used only by
/// [DailyDigestService.generate].
/// The instruction said "resumen de MI día" and the model did as it was told:
/// the digest on the device opened with "Hoy tuve un día con dos registros" —
/// Axi narrating the user's day as its own. The first person was in the
/// instruction, not in the model.
const String kDailyDigestNarrationInstruction =
    'Escribe un resumen breve y cálido del día DEL USUARIO en español neutro, a '
    'partir de sus registros de hoy. Háblale de "tú" ("registraste", "tuviste"), '
    'nunca en primera persona: el día es suyo, no tuyo. Usa solo los hechos '
    'listados; no inventes nada ni agregues datos. Máximo 4 frases.';

/// Builds the on-device daily digest: a DETERMINISTIC aggregation of TODAY's
/// local domain data (grouped by domain + person) plus an OPTIONAL short
/// natural-language wrap-up from the on-device model OVER those facts.
///
/// The factual content is 100% deterministic (never-corrupt-user-data): the
/// model is used ONLY to narrate the already-assembled facts (longsum
/// sampling), never to invent data. A model failure degrades gracefully to the
/// deterministic facts alone.
class DailyDigestService {
  DailyDigestService({
    required LocalDomainRepository repository,
    required LocalGraphStore store,
    required LocalLlmEngine engine,
  })  : _repository = repository, // ignore: prefer_initializing_formals
        _store = store, // ignore: prefer_initializing_formals
        _engine = engine; // ignore: prefer_initializing_formals

  final LocalDomainRepository _repository;
  final LocalGraphStore _store;
  final LocalLlmEngine _engine;

  /// LONGSUM tuned sampling (the summarization role) — low temperature for a
  /// faithful, non-divergent narration. Same values the briefing uses.
  static const double longsumTemperature = 0.2;
  static const int longsumTopK = 20;
  static const double longsumTopP = 0.9;

  /// Aggregate today's data (pure, deterministic) into a structured view — used
  /// by the digest screen and the unified "Mi vida" view.
  Future<DailyDigestData> aggregate({required DateTime now, tz.Location? location}) async {
    final entriesByDomain = <String, List<LocalDomainEntry>>{};
    for (final descriptor in domainDescriptors) {
      // Fetch the whole history for the domain; the aggregator filters to TODAY
      // using [now] in the effective zone ([location] — the override, or null
      // for device-local) so the today-window matches the user's chosen zone.
      entriesByDomain[descriptor.key] =
          await _repository.list(descriptor.key, period: LocalEntryPeriod.todo);
    }
    final directory = PersonDirectory.fromNodes(await _store.listNodesByKind('person'));
    return aggregateDailyDigest(entriesByDomain, now: now, directory: directory, location: location);
  }

  /// Cross-day lines for the summary, best-effort.
  ///
  /// A failure here degrades to the inventory the summary already was, never
  /// to a wrong claim about someone's habits.
  Future<List<String>> _insights({required DateTime now}) async {
    try {
      final timestamps = <String, List<DateTime>>{};
      for (final descriptor in domainDescriptors) {
        final entries = await _repository.list(descriptor.key,
            period: LocalEntryPeriod.todo);
        timestamps[descriptor.key] = [for (final e in entries) e.timestamp];
      }
      final days = digestDaysFrom(timestamps, today: now);
      return [
        ...digestInsights(days, today: now),
        // Cross-domain observations come LAST and only once there is enough
        // history: they are the most interesting line in the summary and the
        // easiest to over-read, so they arrive after the plain facts rather
        // than leading with them.
        ...crossDomainPatterns(days, today: now),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Generate a full digest for [now]. The model wrap-up is shaped by the fixed
  /// internal [kDailyDigestNarrationInstruction] (not user-configurable).
  /// Deterministic facts are always produced; the wrap-up is best-effort.
  Future<DailyDigest> generate({required DateTime now, tz.Location? location}) async {
    final data = await aggregate(now: now, location: location);
    // Rendered in the SAME effective zone the today-window used, so the header
    // date and per-entry times match the aggregated day (AUTOMATIC/null keeps
    // device-local rendering unchanged).
    final facts = renderDigestFacts(data, location: location);

    // What changed ACROSS days. The summary used to be an inventory of today —
    // correct, and saying nothing the user could not get by opening the list.
    // Streaks and gaps are the part worth reading, and they are plain counting:
    // nothing here interprets, advises or claims a correlation.
    final insights = await _insights(now: now);
    final factsWithInsights =
        insights.isEmpty ? facts : '$facts\n\n${insights.join('\n')}';

    if (data.isEmpty) {
      return DailyDigest(
        generatedAt: now,
        // Even on a blank day the streak that just broke is worth saying.
        deterministicText: factsWithInsights,
        wrapUp: '',
        entriesCount: 0,
      );
    }

    var wrapUp = '';
    try {
      await _engine.load();
      final result = await _engine.generate(
        _wrapUpPrompt(facts: facts),
        temperature: longsumTemperature,
        topK: longsumTopK,
        topP: longsumTopP,
      );
      wrapUp = result.text.trim();
    } catch (_) {
      // Model unavailable / degenerated → the deterministic facts stand alone.
      wrapUp = '';
    }

    return DailyDigest(
      generatedAt: now,
      deterministicText: factsWithInsights,
      wrapUp: wrapUp,
      entriesCount: data.totalEntries,
    );
  }

  /// The wrap-up prompt: the fixed internal narration instruction plus the
  /// deterministic facts. The model is explicitly grounded ("usa solo estos
  /// datos") so it narrates, never invents.
  String _wrapUpPrompt({required String facts}) =>
      '$kDailyDigestNarrationInstruction\n\n'
      'Estos son los datos reales de hoy (no agregues nada que no esté aquí):\n\n'
      '$facts';
}
