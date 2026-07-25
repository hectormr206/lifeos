/// On-device OPEN-ENDED relation extractor (the MODEL-based complement).
///
/// Dart port of the laptop `axi/src/axi/extractor.py` contract: after the
/// DETERMINISTIC parsers (health metrics, person naming, subject-stripped facts)
/// have run and NOT fully consumed a chat turn, ask the on-device model to
/// reflect and return STRICT JSON:
///
///   {"facts": [{"label", "domain"}...],
///    "relations": [{"subject", "predicate", "object",
///                   "subject_kind", "object_kind", "aliases"}...]}
///
/// This is what turns Axi from a fixed set of health metrics into "millones de
/// relaciones": ANY named entity (people, medications, conditions, places, orgs,
/// products, events…) and the links between them become first-class graph nodes
/// and edges. It NEVER touches the deterministic path:
///   * Medical/physiological readings are captured deterministically and their
///     turn returns early (the extractor is never called for them); as a second
///     guard, any model fact/relation whose text is a pure LOGGED VITAL
///     ("presión 120/80", "glucosa 95", "dormí 7h", a bare NNN/NN) is dropped
///     ([isLoggedVital]) so the model can never overwrite or duplicate a vital.
///
/// EVERY written fact and generic entity is temporally stamped occurred_at = now
/// (created_at is stamped by the store), and every relation becomes an edge
/// (whose created_at is likewise now) between RESOLVED nodes — reusing
/// [MemoryWriter.ensurePerson] / coref so "mi esposa" maps to the right hub, and
/// [MemoryWriter.ensureEntity] for non-people.
///
/// Defensive by construction (never-corrupt-user-data): a model failure,
/// malformed/empty JSON, or a bad row is a NO-OP — it never crashes the turn and
/// never writes garbage.
library;

import 'dart:convert';

import '../../../core/graph/local_graph_store.dart';
import '../../local_model/domain/local_llm_engine.dart';
import '../data/memory_writer.dart';
import 'subject.dart' show canonRelation, foldAccents;

/// One durable open-ended fact the model surfaced.
class ExtractedFact {
  const ExtractedFact({required this.label, this.domain, this.data = const {}});

  final String label;
  final String? domain;
  final Map<String, Object?> data;
}

/// One subject-predicate-object relation triple the model surfaced.
class ExtractedRelation {
  const ExtractedRelation({
    required this.subject,
    required this.predicate,
    required this.object,
    this.subjectKind,
    this.objectKind,
    this.aliases = const <String>[],
  });

  final String subject;
  final String predicate;
  final String object;
  final String? subjectKind;
  final String? objectKind;
  final List<String> aliases;
}

/// The parsed `{facts, relations}` payload. [isEmpty] when nothing was found —
/// the explicit "nothing worth remembering" path.
class Extraction {
  const Extraction({this.facts = const [], this.relations = const []});

  final List<ExtractedFact> facts;
  final List<ExtractedRelation> relations;

  bool get isEmpty => facts.isEmpty && relations.isEmpty;
}

// ── Logged-vital guard (ported from extractor.py `_VITAL_PATTERNS`) ──────────
//
// Matches ONLY pure numeric vital/measurement shapes the deterministic health
// parser already logs — never prose. Written UNACCENTED and matched against
// folded text (Dart `\b` is ASCII-only), same convention as health_parser.
final List<RegExp> _vitalPatterns = <RegExp>[
  // "120/80", "114/81" — but NOT a 3-group calendar date like 14/03/2020.
  RegExp(r'(?<![\d/])\d{2,3}\s*/\s*\d{2,3}(?![\d/])'),
  RegExp(r'\b(?:presion|tension)\b[^.\d]{0,12}\d', caseSensitive: false),
  RegExp(r'\b(?:glucosa|glucemia|azucar)\b[^.\d]{0,12}\d', caseSensitive: false),
  RegExp(r'\b(?:peso|pese)\b[^.\d]{0,12}\d', caseSensitive: false),
  RegExp(r'\btemperatura\b[^.\d]{0,12}\d', caseSensitive: false),
  RegExp(r'\b(?:pulso|frecuencia\s+cardiaca|fc|bpm)\b[^.\d]{0,12}\d',
      caseSensitive: false),
  RegExp(r'\b\d{2,3}\s*bpm\b', caseSensitive: false),
  RegExp(r'\bdorm\w*\b[^.\d]{0,12}\d+\s*h', caseSensitive: false),
  RegExp(r'\b\d+\s*h(?:oras)?\s+de\s+sueno\b', caseSensitive: false),
];

/// True only when [text] is a pure numeric vital/measurement the deterministic
/// health path already owns — so the model extractor never re-logs it.
bool isLoggedVital(String text) {
  final t = foldAccents(text.trim().toLowerCase());
  if (t.isEmpty) return false;
  return _vitalPatterns.any((p) => p.hasMatch(t));
}

/// Parse the model's raw output into an [Extraction], recovering JSON even when
/// the model wraps it in markdown fences or adds prose (ported from
/// extractor.py `_parse_json_strict`). Returns null when nothing usable is
/// found — the caller treats null as a no-op.
Extraction? parseExtraction(String raw) {
  final obj = _recoverJsonObject(raw);
  if (obj == null) return null;

  final facts = <ExtractedFact>[];
  final rawFacts = obj['facts'];
  if (rawFacts is List) {
    for (final f in rawFacts) {
      if (f is! Map) continue;
      final label = (f['label'] as Object?)?.toString().trim() ?? '';
      if (label.isEmpty) continue;
      var domain = (f['domain'] as Object?)?.toString().trim();
      if (domain == null || domain.isEmpty || domain == 'null') domain = null;
      final data = f['data'] is Map
          ? Map<String, Object?>.from(f['data'] as Map)
          : const <String, Object?>{};
      facts.add(ExtractedFact(label: label, domain: domain, data: data));
    }
  }

  final relations = <ExtractedRelation>[];
  final rawRels = obj['relations'];
  if (rawRels is List) {
    for (final r in rawRels) {
      if (r is! Map) continue;
      final subject = (r['subject'] as Object?)?.toString().trim() ?? '';
      // Accept both `predicate` (this port's contract) and `relation` (the
      // laptop key) so either shape parses.
      final predicate =
          ((r['predicate'] ?? r['relation']) as Object?)?.toString().trim() ??
              '';
      final object = (r['object'] as Object?)?.toString().trim() ?? '';
      if (subject.isEmpty || predicate.isEmpty || object.isEmpty) continue;
      relations.add(ExtractedRelation(
        subject: subject,
        predicate: predicate,
        object: object,
        subjectKind: (r['subject_kind'] as Object?)?.toString().trim(),
        objectKind: (r['object_kind'] as Object?)?.toString().trim(),
        aliases: (r['aliases'] is List)
            ? (r['aliases'] as List)
                .map((a) => a.toString().trim())
                .where((a) => a.isNotEmpty)
                .toList()
            : const <String>[],
      ));
    }
  }

  return Extraction(facts: facts, relations: relations);
}

Map<String, Object?>? _recoverJsonObject(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  // Strip a ```json … ``` fence if present.
  final fence = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```').firstMatch(text);
  if (fence != null) text = fence.group(1)!;
  // Otherwise seek the first top-level object.
  if (!text.startsWith('{')) {
    final idx = text.indexOf('{');
    if (idx == -1) return null;
    text = text.substring(idx);
  }
  final decoded = _tryDecode(text) ?? _tryDecode(_trimToLastBrace(text));
  if (decoded is Map) return Map<String, Object?>.from(decoded);
  return null;
}

Object? _tryDecode(String? text) {
  if (text == null) return null;
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

String? _trimToLastBrace(String text) {
  final last = text.lastIndexOf('}');
  return last == -1 ? null : text.substring(0, last + 1);
}

/// Runs one open-ended extraction pass over a finished chat turn and writes the
/// result through the EXISTING memory write path. Stateless.
class RelationExtractor {
  RelationExtractor({
    required this.engine,
    required this.writer,
    required this.store,
    required this.now,
    this.languageCode = 'es',
  });

  final LocalLlmEngine engine;
  final MemoryWriter writer;
  final LocalGraphStore store;
  final DateTime Function() now;
  final String languageCode;

  /// EXTRACTION sampling — low temperature for a faithful, reproducible,
  /// structured (JSON) response. Mirrors the LONGSUM recipe already used for the
  /// on-device structured/narration tasks (see
  /// `DailyDigestService.longsum*` in features/daily_digest/data — 0.2 / 20 /
  /// 0.9, itself the model_audit tune-to-peak longsum row). NOT invented here.
  static const double extractionTemperature = 0.2;
  static const int extractionTopK = 20;
  static const double extractionTopP = 0.9;

  /// Folded tokens that mean "the user" as a relation subject/object → the hub.
  static const Set<String> _userTokens = <String>{
    'hector', 'yo', 'me', 'mi', 'i', 'yo mismo',
  };

  /// Extract facts + relations from the turn and persist them. Best-effort: a
  /// model failure or malformed JSON is a silent no-op (never throws).
  ///
  /// [subject] is the DETERMINISTIC segment subject (canonical relation label,
  /// e.g. "esposa") when the whole extractable content of the turn belongs to
  /// one family member; extracted facts are then written with that subject
  /// (data.subject + the fact--involves-->person edge) instead of defaulting
  /// to the user. It comes ONLY from the utterance segmenter — the model never
  /// chooses who a fact is about. Null keeps the user attribution.
  Future<void> extractAndWrite(
    String userText,
    String axiText, {
    String? subject,
  }) async {
    Extraction? extraction;
    try {
      await engine.load();
      final result = await engine.generate(
        _buildPrompt(userText, axiText),
        temperature: extractionTemperature,
        topK: extractionTopK,
        topP: extractionTopP,
      );
      extraction = parseExtraction(result.text);
    } catch (_) {
      return; // model/parse failure → no-op, never crash the turn.
    }
    if (extraction == null || extraction.isEmpty) return;

    final at = now();

    for (final f in extraction.facts) {
      // Never re-log a pure vital the deterministic health path already owns.
      if (isLoggedVital(f.label)) continue;
      try {
        await writer.writeFact(
          domain: f.domain,
          label: f.label,
          // occurred_at = now for EVERY extracted fact.
          occurredAt: at,
          // Deterministic segment subject (or null = the user) — see
          // [extractAndWrite]. Keeps a family member's fact off the user's
          // own record.
          subject: subject,
          data: <String, Object?>{
            'source': 'relation_extractor',
            ...f.data,
          },
        );
      } catch (_) {
        // One bad fact must never abort the rest of the pass.
      }
    }

    for (final r in extraction.relations) {
      try {
        await _writeRelation(r, at);
      } catch (_) {
        // One bad relation must never abort the rest of the pass.
      }
    }
  }

  Future<void> _writeRelation(ExtractedRelation r, DateTime at) async {
    final predicate = r.predicate.trim();
    final subject = r.subject.trim();
    final object = r.object.trim();
    if (predicate.isEmpty || subject.isEmpty || object.isEmpty) return;
    // Never mint entities out of bare numeric vitals.
    if (isLoggedVital(subject) || isLoggedVital(object)) return;

    final canonPredicate =
        canonRelation(foldAccents(predicate.toLowerCase()));

    // Crown-jewel path: "yo --esposa--> Celia" resolves/creates the esposa
    // person node and NAMES it (reusing the typed hub edge + coref merge), so a
    // later "de mi esposa …" maps to the same hub — exactly like the
    // deterministic naming path.
    if (_isUser(subject) && canonPredicate != null) {
      final name = foldAccents(object.toLowerCase()) == canonPredicate
          ? null // model echoed the relation word instead of a real name
          : object;
      final uuid = await writer.ensurePerson(predicate, name: name);
      for (final a in r.aliases) {
        await writer.registerAlias(uuid, a);
      }
      return;
    }

    final srcUuid = await _resolveNode(subject, r.subjectKind, at);
    final dstUuid = await _resolveNode(object, r.objectKind, at);
    if (srcUuid == dstUuid) return;
    // The edge's created_at (now) is the relation's temporal stamp.
    await store.createEdge(
      srcUuid: srcUuid,
      dstUuid: dstUuid,
      relation: predicate,
    );
    for (final a in r.aliases) {
      await writer.registerAlias(dstUuid, a);
    }
  }

  /// Resolve one relation endpoint to a node uuid: the user hub, a family-
  /// relation person (reusing coref), or a generic entity node.
  Future<String> _resolveNode(String term, String? kindHint, DateTime at) async {
    if (_isUser(term)) return writer.ensureUserHub();
    final canon = canonRelation(foldAccents(term.toLowerCase()));
    if (canon != null) {
      // A relation WORD as an endpoint ("esposa") → the resolved relation person.
      return writer.ensurePerson(term);
    }
    final kind = kindHint == 'person' ? 'person' : 'entity';
    return writer.ensureEntity(term, kind: kind, occurredAt: at);
  }

  static bool _isUser(String term) =>
      _userTokens.contains(foldAccents(term.trim().toLowerCase()));

  /// The strict-JSON extraction prompt (ported, condensed, from
  /// extractor.py `_EXTRACTOR_SYSTEM_TEMPLATE`). Spanish, with today's date so
  /// the model can turn relative times into an approximate absolute — it is
  /// forbidden from inventing exact dates.
  String _buildPrompt(String userText, String axiText) {
    final hoy = _todayString();
    final en = languageCode == 'en';
    final header = en
        ? 'You extract durable facts and relations for long-term memory. TODAY is $hoy.'
        : 'Eres un extractor de hechos y relaciones para la memoria de largo plazo. HOY es $hoy.';
    return '$header\n'
        'Del siguiente intercambio, identifica de 0 a 4 hechos DURADEROS sobre el '
        'usuario (preferencias, biográficos, decisiones, planes, salud, '
        'finanzas, relaciones, contexto profesional) y las RELACIONES entre '
        'entidades NOMBRADAS y concretas.\n'
        'Reglas: usa el label en presente y específico, con nombres/fechas/'
        'cantidades textuales. NO extraigas mediciones numéricas sueltas de '
        'vitales (presión 120/80, glucosa 95, peso 64, dormí 7h): otro canal las '
        'registra. Cada relación es un triple sujeto-predicado-objeto; usa '
        'EXACTAMENTE la palabra de vínculo que usó el usuario (esposa, primo, '
        'padece, tratada_con…), nunca la degrades. Solo relaciones dichas '
        'EXPLÍCITAMENTE. Ante la duda, omite.\n'
        'Responde SOLO con JSON válido, sin texto antes ni después, con esta '
        'forma exacta:\n'
        '{"facts":[{"label":"...","domain":"health|finance|work|home|setup|'
        'personal|null"}],'
        '"relations":[{"subject":"<entidad o \'yo\'>","predicate":"<vínculo>",'
        '"object":"<entidad>","subject_kind":"person|condition|medication|place|'
        'org|product|event|thing","object_kind":"...","aliases":[]}]}\n'
        'Si no hay nada que extraer: {"facts":[],"relations":[]}\n\n'
        'Usuario dijo: $userText\n\nAxi respondió: $axiText';
  }

  String _todayString() {
    final d = now();
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }
}
