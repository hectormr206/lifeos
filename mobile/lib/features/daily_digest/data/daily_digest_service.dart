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

/// FIXED, internal narration instruction that shapes the on-device model's
/// natural-language wrap-up over the deterministically-assembled facts.
///
/// This is a PRODUCT-OWNED constant: it is NOT user-editable, NOT surfaced in
/// the UI, and NOT read from or written to preferences. The digest still needs
/// a narration instruction for the model, so it lives here and is used only by
/// [DailyDigestService.generate].
const String kDailyDigestNarrationInstruction =
    'Escribe un resumen breve y cálido de mi día en español neutro, a partir de '
    'los registros de hoy. Usa solo los hechos listados; no inventes nada ni '
    'agregues datos. Máximo 4 frases.';

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

  /// Generate a full digest for [now]. The model wrap-up is shaped by the fixed
  /// internal [kDailyDigestNarrationInstruction] (not user-configurable).
  /// Deterministic facts are always produced; the wrap-up is best-effort.
  Future<DailyDigest> generate({required DateTime now, tz.Location? location}) async {
    final data = await aggregate(now: now, location: location);
    // Rendered in the SAME effective zone the today-window used, so the header
    // date and per-entry times match the aggregated day (AUTOMATIC/null keeps
    // device-local rendering unchanged).
    final facts = renderDigestFacts(data, location: location);

    if (data.isEmpty) {
      return DailyDigest(
        generatedAt: now,
        deterministicText: facts,
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
      deterministicText: facts,
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
