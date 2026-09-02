/// On-device chat context builder (roadmap SLICE C1).
///
/// This is the ONE place that turns a raw user turn into (a) the full prompt
/// preamble Axi generates against — persona + language/datetime + a relevant
/// MEMORY block — and (b) the WRITE-BACK of the exchange into the graph so Axi
/// remembers next time. It COMPOSES the pieces built in earlier slices and owns
/// no storage/model itself:
///   * A3: [DomainRouter], [MemoryWriter], [buildRecallBlock], subject helpers.
///   * B1: [RagService] (semantic recall + indexing) over [LocalGraphStore].
///   * i18n: [decorateWithAxiContext] / [axiBehaviorPrompt].
///
/// Everything the builder needs at runtime is resolved lazily through
/// [ChatContextDepsLoader] (the graph store opens async; the embedding stack may
/// be unavailable), so the builder itself is a pure, Riverpod-free unit that a
/// test drives with an in-memory store + a fake embedder — or none at all.
///
/// RECALL FALLBACK: semantic recall ([RagService.recallByText]) is tried first
/// when an embedder is wired; on ANY failure (the flutter_gemma embedding
/// backend may not be registered yet) or an empty result it falls back to a
/// LEXICAL keyword search over [LocalGraphStore.searchNodes], which works with
/// no model at all. RAM load-around-the-turn: the embedder is DISPOSED right
/// after the query is embedded (before the LLM generates) so only the LLM is
/// hot at generation time.
library;

import 'dart:async';

import 'package:timezone/timezone.dart' as tz;

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../../domains/data/local_domain_repository.dart';
import '../../domains/domain/local_entry_config.dart';
import '../../embedding/domain/rag_service.dart';
import '../../local_model/domain/local_llm_engine.dart';
import 'person_facts.dart';
import '../../memory/domain/query_date_range.dart';
import '../../memory/domain/when_answer.dart';
import '../../memory/data/memory_writer.dart';
import '../../memory/domain/domain_router.dart';
import '../../memory/domain/health_parser.dart';
import '../../memory/domain/person_directory.dart';
import '../../memory/domain/person_naming.dart';
import '../../memory/domain/relation_extractor.dart';
import '../../memory/domain/recall_block.dart';
import 'order_to_axi.dart';
import '../../memory/domain/subject.dart';
import '../../memory/domain/user_naming.dart';
import '../../memory/domain/utterance_segmenter.dart';
import 'axi_prompt_context.dart';

/// The user's onboarding identity as seen through the graph store.
///
/// [available] separates "memory is reachable" from "the name is known": a null
/// [name] with [available] true means the user has NOT told us their name yet
/// (first-run onboarding should greet + ask), whereas [available] false means
/// the store could not be opened this call (skip onboarding, degrade silently).
class UserIdentity {
  const UserIdentity({required this.available, this.name});

  final bool available;
  final String? name;
}

/// The runtime dependencies the builder composes, resolved lazily per turn.
///
/// [rag] is null when the embedding stack is unavailable — recall then runs
/// LEXICALLY over [store] and no fact is vector-indexed on write.
///
/// [engine] is the on-device LLM used for OPEN-ENDED relation extraction (the
/// model-based complement to the deterministic parsers). Null → that step is
/// skipped and only the deterministic capture runs (the chat still answers).
class ChatContextDeps {
  const ChatContextDeps({
    required this.store,
    required this.writer,
    this.rag,
    this.engine,
  });

  final LocalGraphStore store;
  final MemoryWriter writer;
  final RagService? rag;
  final LocalLlmEngine? engine;
}

/// Resolves [ChatContextDeps] for a turn, or null when the graph store is
/// unavailable (memory degrades to OFF for that turn — the chat still answers).
typedef ChatContextDepsLoader = Future<ChatContextDeps?> Function();

/// ONE thing the DETERMINISTIC capture actually wrote for a turn — the raw
/// material of Axi's "Anotado en Salud: …" acknowledgment (laptop parity).
///
/// [domainKey] is a [DomainDescriptor.key] (`health`, `exercise`, …) so the UI
/// can label it with the same domain title the rest of the app shows.
/// [title] is the normalized label that was stored ("presión 122/77, pulso 55").
/// [subject] is the person the entry belongs to, already resolved to a DISPLAY
/// name ("Celia") when known, or null when the entry is the user's own.
class CaptureEntry {
  const CaptureEntry({
    required this.domainKey,
    required this.title,
    this.subject,
  });

  final String domainKey;
  final String title;
  final String? subject;

  CaptureEntry withSubjectDisplay(String? display) => CaptureEntry(
        domainKey: domainKey,
        title: title,
        subject: display,
      );
}

/// What the deterministic (model-free) capture wrote for one user turn.
///
/// [entries] is what the chat can CONFIRM back to the user by domain; empty
/// means nothing domain-typed was written — the turn is then answered normally
/// (model), UNLESS [wroteDomainlessFact] says something was still stored, in
/// which case it gets the generic acknowledgment rather than silence.
/// [hasNonHealthContent] is the gate for the model-based open-ended extractor —
/// a purely medical turn never touches the model.
class CaptureSummary {
  const CaptureSummary({
    this.entries = const <CaptureEntry>[],
    this.hasNonHealthContent = false,
    this.nonHealthSubject,
    this.wroteDomainlessFact = false,
  });

  const CaptureSummary.empty() : this();

  final List<CaptureEntry> entries;
  final bool hasNonHealthContent;

  /// True when the turn really wrote a fact that has NO domain — nothing to say
  /// "Anotado en <Dominio>" about, and nothing that will ever show up in "Mi
  /// vida", but a write all the same.
  ///
  /// It exists so the turn can still be ACKNOWLEDGED. Writing into someone's
  /// memory and saying nothing is the worst of the three outcomes: not storing
  /// it is honest, storing it and saying so is useful, storing it in silence
  /// leaves something the user cannot see, cannot correct, and does not know is
  /// there. The caller answers these with the generic acknowledgment
  /// (`acknowledgeStatement`), which claims a save and NOT a category —
  /// because a category is exactly what this fact does not have.
  final bool wroteDomainlessFact;

  /// The DETERMINISTIC segment subject (canonical relation label, "esposa")
  /// shared by ALL the non-health clauses of the turn, or null when they are
  /// the user's own (or mixed). Passed to the model-based extractor so a fact
  /// it surfaces from a subject-tagged turn ("mi esposa empezó a tomar
  /// losartán") is filed under that person, never as the user's own. The model
  /// NEVER chooses the subject — only the segmenter's resolution flows here.
  final String? nonHealthSubject;

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;
}

/// The model-free triage of a turn: its subject-attributed segments plus any
/// whole-turn explicit person naming. Null (see [_planCapture]) means the turn
/// carries no deterministic capture signal at all.
class _CapturePlan {
  const _CapturePlan({required this.segments, this.naming});

  final List<UtteranceSegment> segments;
  final PersonNaming? naming;
}

/// Builds the per-turn prompt preamble and writes the exchange back to memory.
class ChatContextBuilder {
  ChatContextBuilder({
    required this.loadDeps,
    required this.languageCode,
    required this.now,
    this.wallClockNow,
    this.zoneLocation,
    this.router = const DomainRouter(),
    this.segmenter = const UtteranceSegmenter(),
    this.recallK = 8,
  });

  final ChatContextDepsLoader loadDeps;
  final String Function() languageCode;
  final DateTime Function() now;

  /// "What time is it on the wall RIGHT NOW", in the user's EFFECTIVE timezone
  /// (`EffectiveTimezone.overrideLocation` applied), used ONLY for deterministic
  /// clock math — today the natural-language sleep duration ("me dormí a las 12
  /// am y acabo de despertar" → the hours until now).
  ///
  /// Deliberately SEPARATE from [now]: [now] is the instant that timestamps what
  /// we store, and it must stay device-local/UTC-consistent, while clock math
  /// needs the user's wall-clock HOUR. Null → falls back to [now].
  final DateTime Function()? wallClockNow;

  /// The zone the user reads in — the configured one, not just the device's.
  ///
  /// The graph stores instants in UTC, so every hour shown to a person has to
  /// be converted. Printing the raw value reported 15:16 for a weight logged
  /// at 09:16 in Mexico City: the right instant in the wrong zone, which for
  /// someone reading it is simply the wrong time.
  final tz.Location? Function()? zoneLocation;

  final DomainRouter router;

  /// Splits a single dictated turn into subject-attributed clauses so a
  /// multi-topic / multi-person line is captured on the correct hubs.
  final UtteranceSegmenter segmenter;

  final int recallK;

  /// Build the full prompt text for [message]: Axi's behavior prompt + the
  /// language/datetime lines + a relevant MEMORY block, then the message.
  ///
  /// NEVER throws and never blocks on memory: any retrieval failure degrades to
  /// an empty memory block (persona + language + datetime still ship), so a turn
  /// is always answerable.
  Future<String> buildPreamble(String message) async {
    final lang = languageCode();
    final at = now();
    var memoryBlock = '';
    String? userName;
    try {
      final deps = await loadDeps();
      if (deps != null) {
        // The captured name (first-run onboarding) so Axi addresses the user by
        // name and "yo/mi" anchors to the user hub. Best-effort like recall.
        userName = await deps.writer.userDisplayName();
        final recalled = await _recallNodes(deps, message);
        final named = await _byName(deps, recalled, message);
        // Facts found BY NAME skip the domain filter: the user naming someone
        // outranks the router's guess about what the question is about.
        final facts = _factsFrom(
          named,
          message,
          exemptFromDomain: {
            for (final n in named)
              if (!recalled.any((r) => r.uuid == n.uuid)) n.uuid,
          },
        );
        // Bonds and facts are gathered from the SAME recall, so a question that
        // surfaces a person brings that person's relationships with it.
        final bonds = await _relationshipsFor(deps, named, message);
        // Diagnostic, and deliberately CONTENT-FREE: counts only, never a name
        // and never a remembered line. Added after three rounds of guessing why
        // "¿qué relación tengo con X?" found nothing while "¿quién es X?"
        // answered correctly — a log that cannot be read on the device is a
        // question that can only be answered by rebuilding.
        // `print`, not `developer.log`: the latter goes to the VM service and
        // never reaches logcat in a release build, which is the only build that
        // runs on the test device. A diagnostic you cannot read where the bug
        // happens is not a diagnostic.
        // ignore: avoid_print
        print('LIFEOS_RECALL names=${properNounsInMessage(message).length} '
            'recalled=${recalled.length} named=${named.length} '
            'facts=${facts.length} bonds=${bonds.length}');
        // A STATEMENT, not a rule. Asked about a name with nothing stored, the
        // model answered "Mariana es tu esposa" — a relationship invented about
        // a real person. Filtering the block down to one fact did not stop it:
        // the invention needs no source material.
        //
        // Conditional rules ("if the name is absent, say you don't know") were
        // tried four times on this ~2B model and each attempt broke something
        // that worked. A flat sentence of fact is a different kind of input,
        // and it is the one small models follow.
        final unknown = [
          for (final name in properNounsInMessage(message))
            if (!facts.any((f) =>
                    f.label.toLowerCase().contains(name.toLowerCase())) &&
                !bonds.any((b) =>
                    b.toLowerCase().contains(name.toLowerCase())))
              name,
        ];
        final unknownLine = unknown.isEmpty
            ? ''
            : (lang == 'en'
                ? 'You have NOTHING stored about: ${unknown.join(', ')}. '
                    'Say you do not know who they are.'
                : 'No tienes NADA guardado sobre: ${unknown.join(', ')}. '
                    'Di que no sabes quién es.');
        memoryBlock = composeMemoryBlock(
          relationships: bonds,
          factsBlock: [
            buildRecallBlock(message, facts,
                en: lang == 'en', now: at, location: zoneLocation?.call()),
            unknownLine,
          ].where((s) => s.trim().isNotEmpty).join('\n\n'),
          en: lang == 'en',
        );
      }
    } catch (_) {
      // Memory is best-effort context — never let it break a generation.
    }
    return decorateWithAxiContext(
      message: message,
      languageCode: lang,
      now: at,
      memoryBlock: memoryBlock,
      userName: userName,
    );
  }

  /// The user's first-run identity (memory availability + known name). Never
  /// throws; an unreachable store returns `available: false` so the caller can
  /// tell "no name yet" apart from "no store this call".
  Future<UserIdentity> userIdentity() async {
    try {
      final deps = await loadDeps();
      if (deps == null) return const UserIdentity(available: false);
      final name = await deps.writer.userDisplayName();
      return UserIdentity(available: true, name: name);
    } catch (_) {
      return const UserIdentity(available: false);
    }
  }

  /// DETERMINISTICALLY capture the user's OWN name from [userText] and store it
  /// on the user hub (first-run onboarding). Parses BEFORE touching the store,
  /// so a message that carries no name never reads the graph. When
  /// [answeringNamePrompt] is true (the last bubble was Axi's onboarding
  /// question) a BARE reply like "Héctor" is accepted; otherwise only explicit
  /// "me llamo …" / "soy …" forms are.
  ///
  /// Never invokes the model. Returns the stored display name, or null when
  /// nothing name-like was found, the store is unavailable, or a name is already
  /// known (a captured name is never silently overwritten from chat).
  Future<String?> captureUserName(
    String userText, {
    required bool answeringNamePrompt,
  }) async {
    final candidate = parseUserName(userText, bareAllowed: answeringNamePrompt);
    if (candidate == null) return null;
    try {
      final deps = await loadDeps();
      if (deps == null) return null;
      final existing = await deps.writer.userDisplayName();
      if (existing != null && existing.isNotEmpty) return null;
      await deps.writer.setUserName(candidate);
      return candidate;
    } catch (_) {
      return null;
    }
  }

  /// Persist the finished exchange (roadmap SLICE C1, write half). Best-effort:
  /// always writes the conversation turn; when [userText] reads as a personal
  /// STATEMENT (not a question), also extracts a concise fact and — when an
  /// embedder is wired — vector-indexes it so it is semantically recallable.
  ///
  /// NEVER throws; callers fire this `unawaited` so it can neither block nor
  /// reorder the FIFO send flow.
  ///
  /// PROVENANCE (data-control kit): when the caller knows which chat
  /// conversation/message produced this turn, it passes
  /// [sourceConversationUuid] / [sourceMessageId] and BOTH the conversation-
  /// turn node and any derived fact are stamped with them (in `data`, no
  /// schema change) — that stamp is what lets "Eliminar conversación/mensaje"
  /// cascade-delete the memories the exchange produced.
  Future<void> recordTurn({
    required String userText,
    required String axiText,
    String? sourceConversationUuid,
    String? sourceMessageId,
  }) async {
    await recordConversationTurn(
      userText: userText,
      axiText: axiText,
      sourceConversationUuid: sourceConversationUuid,
      sourceMessageId: sourceMessageId,
    );
    final summary = await captureTurn(
      userText,
      sourceConversationUuid: sourceConversationUuid,
      sourceMessageId: sourceMessageId,
    );
    await extractOpenEnded(
      userText: userText,
      axiText: axiText,
      summary: summary,
    );
  }

  /// Persist ONLY the durable dialogue record (kind 'conversation'; excluded
  /// from fact recall). Split out of [recordTurn] because the deterministic
  /// capture now runs BEFORE the reply exists (it may BE the reply), while the
  /// turn itself can only be stored once the shown reply is known.
  ///
  /// Never throws (best-effort by contract).
  Future<void> recordConversationTurn({
    required String userText,
    required String axiText,
    String? sourceConversationUuid,
    String? sourceMessageId,
  }) async {
    try {
      final deps = await loadDeps();
      if (deps == null) return;
      final provenance = _provenance(sourceConversationUuid, sourceMessageId);
      await deps.writer.writeConversationTurn(
        userText: userText,
        axiText: axiText,
        data: provenance.isEmpty ? null : provenance,
      );
    } catch (_) {
      // Best-effort memory write; a failure never surfaces to the user.
    }
  }

  /// SYNCHRONOUS, model-free, store-free triage: could [userText] produce a
  /// deterministic capture at all? The exact same predicate [captureTurn] uses,
  /// exposed so the chat can decide whether to even take the async capture path
  /// (an ordinary message goes STRAIGHT to the model — no store read, no extra
  /// async hop, no added latency).
  bool looksCapturable(String userText) => _planCapture(userText) != null;

  /// Run the DETERMINISTIC (model-free) capture for [userText] and report WHAT
  /// was written, so the chat can confirm it back to the user instead of asking
  /// the model for a reply (laptop parity: `dashboard.py` answers a structured
  /// health capture with "Anotado en salud como vital: …").
  ///
  /// Writes exactly what [recordTurn] used to write in its capture half: typed
  /// domain entries for medical readings, graph facts for the other clauses,
  /// explicit person naming, and best-effort vector indexing. It does NOT store
  /// the conversation turn ([recordConversationTurn]) and NEVER invokes the
  /// model ([extractOpenEnded] does, afterwards).
  ///
  /// Never throws: on any failure the entries written so far are still
  /// reported, so the acknowledgment only ever claims real writes.
  Future<CaptureSummary> captureTurn(
    String userText, {
    String? sourceConversationUuid,
    String? sourceMessageId,
  }) async {
    // ── DETERMINISTIC multi-topic / multi-person SEGMENTATION, FIRST ─────────
    // A single dictated line often braids several topics AND several people
    // ("122 77 55 pulsos, corrí 5km …, y de mi esposa son 120 60 49 pulsos").
    // Split it into subject-attributed clauses so EACH reading/note lands on
    // the right hub, and a family-subject marker is LOCAL to its clause —
    // never a global whole-string scan that hijacks the whole utterance.
    // Model-free.
    final plan = _planCapture(userText);
    if (plan == null) return const CaptureSummary.empty();

    final entries = <CaptureEntry>[];
    var hasNonHealthContent = false;
    var wroteDomainlessFact = false;
    final nonHealthSubjects = <String?>{};
    ChatContextDeps? deps;
    try {
      deps = await loadDeps();
      if (deps == null) return const CaptureSummary.empty();
      final provenance = _provenance(sourceConversationUuid, sourceMessageId);

      // ── Deterministic explicit name/nickname learning (whole-turn scoped) ──
      // "mi esposa se llama Celia" / "a mi papá le decimos Beto" upgrades the
      // relation's person node to a real named node (label + alias). The
      // clause(s) still fall through to the normal per-segment write below.
      final naming = plan.naming;
      if (naming != null) {
        await deps.writer.learnPersonName(
          naming.relation,
          name: naming.name,
          alias: naming.alias,
        );
      }

      // ── Per-segment capture ────────────────────────────────────────────────
      // Medical readings are captured 100% deterministically on the segment's
      // resolved subject; every other clause becomes a fact on the right hub.
      final segments = plan.segments;
      for (var i = 0; i < segments.length; i++) {
        final seg = segments[i];

        // Structured health capture (crown jewel): a hit lands as a TYPED domain
        // entry (visible in the domains list) plus its graph fact, attributed to
        // THIS clause's subject (122 → me, 120 → Celia). Medical numbers are
        // NEVER routed through the model.
        final parsed =
            parseHealthCore(seg.text, now: _wallNow())?.withSubject(seg.subject);
        if (parsed != null) {
          final entryType = localEntryTypeFor(parsed.domainKey, parsed.type);
          if (entryType != null) {
            final structured = await _captureStructured(
              deps,
              parsed,
              entryType,
              provenance,
              userText,
              sourceMessageId,
              sourceConversationUuid,
              i,
            );
            await _indexIfPossible(deps, structured);
            entries.add(CaptureEntry(
              domainKey: parsed.domainKey,
              title: parsed.title,
              subject: parsed.subject,
            ));
            continue; // this reading is owned deterministically.
          }
        }

        // Unparsed clause. If it still LOOKS medical (vital keywords/numbers
        // the health parser owns — [isLoggedVital] — even though this exact
        // shape missed), it must NOT by itself open the model-extractor gate:
        // a purely medical turn never touches the model. The clause is still
        // written as a raw fact below, so nothing is lost.
        if (!isLoggedVital(seg.text)) {
          hasNonHealthContent = true;
          nonHealthSubjects.add(seg.subject);
        }
        final fact = await _captureSegmentFact(deps, seg, provenance);
        final entry = fact.entry;
        if (entry != null) entries.add(entry);
        if (fact.domainlessWrite) wroteDomainlessFact = true;
      }
    } catch (_) {
      // Best-effort memory write; a failure never surfaces to the user. What
      // WAS written up to here is still reported (and only that).
    }
    return CaptureSummary(
      entries: await _resolveSubjectNames(deps, entries),
      hasNonHealthContent: hasNonHealthContent,
      // Deterministic subject for the extractor: only when EVERY non-health
      // clause resolved to the SAME family member. Mixed or user-owned → null
      // (user attribution, the safe default).
      nonHealthSubject: nonHealthSubjects.length == 1 ? nonHealthSubjects.single : null,
      wroteDomainlessFact: wroteDomainlessFact,
    );
  }

  /// Open-ended relation extraction (model-based complement). Runs ONLY when
  /// the turn carried NON-health content the deterministic parsers could not
  /// fully own (a pure-medical turn never touches the model). Callers fire this
  /// AFTER the reply is on screen so the model can never delay it.
  ///
  /// Best-effort; person routing + medical values NEVER depend on it, and
  /// isLoggedVital inside the extractor still guards every write.
  Future<void> extractOpenEnded({
    required String userText,
    required String axiText,
    required CaptureSummary summary,
  }) async {
    if (!summary.hasNonHealthContent) return;
    try {
      final deps = await loadDeps();
      final engine = deps?.engine;
      if (deps == null || engine == null) return;
      await RelationExtractor(
        engine: engine,
        writer: deps.writer,
        store: deps.store,
        now: now,
      ).extractAndWrite(
        userText,
        axiText,
        // Deterministic segment subject (never model-chosen): facts from a
        // subject-tagged turn are filed under that person.
        subject: summary.nonHealthSubject,
      );
    } catch (_) {
      // Best-effort model complement; a failure never surfaces to the user.
    }
  }

  /// The wall clock for deterministic clock math: [wallClockNow] when the
  /// timezone-aware seam is wired, else the plain [now].
  DateTime _wallNow() => (wallClockNow ?? now)();

  /// The model-free capture triage shared by [looksCapturable] and
  /// [captureTurn]: segments + whole-turn naming, or null when the turn carries
  /// no deterministic signal at all (no reading, no naming, no statement).
  _CapturePlan? _planCapture(String userText) {
    final segments = segmenter.segment(userText);
    final naming = detectPersonNaming(userText);
    final wall = _wallNow();
    final anyHealth =
        segments.any((s) => parseHealthCore(s.text, now: wall) != null);
    if (!anyHealth && naming == null && !_looksLikeStatement(userText)) {
      return null;
    }
    return _CapturePlan(segments: segments, naming: naming);
  }

  /// PROVENANCE stamp for everything one turn writes (see [recordTurn]).
  static Map<String, Object?> _provenance(
    String? sourceConversationUuid,
    String? sourceMessageId,
  ) =>
      <String, Object?>{
        kSourceConversationKey: ?sourceConversationUuid,
        kSourceMessageKey: ?sourceMessageId,
      };

  /// Map each entry's raw relation label ("esposa") to the person's DISPLAY name
  /// ("Celia") using the person hub, so the acknowledgment names the person the
  /// user knows. Best-effort: an unreachable hub keeps the relation label.
  Future<List<CaptureEntry>> _resolveSubjectNames(
    ChatContextDeps? deps,
    List<CaptureEntry> entries,
  ) async {
    if (deps == null || entries.every((e) => e.subject == null)) return entries;
    try {
      final directory = PersonDirectory.fromNodes(
        await deps.store.listNodesByKind('person'),
      );
      return <CaptureEntry>[
        for (final e in entries)
          e.subject == null
              ? e
              : e.withSubjectDisplay(directory.displayFor(e.subject)),
      ];
    } catch (_) {
      return entries;
    }
  }

  /// Land a parsed health reading as a STRUCTURED domain entry (+ its graph
  /// fact) via [LocalDomainRepository]. The entryId is DETERMINISTIC (keyed on
  /// the source message) so a retry of the same turn dedupes; provenance +
  /// raw utterance ride along so conversation-delete cascade reaches it.
  Future<GraphNodeRecord?> _captureStructured(
    ChatContextDeps deps,
    ParsedEntry parsed,
    LocalEntryType entryType,
    Map<String, Object?> provenance,
    String userText,
    String? sourceMessageId,
    String? sourceConversationUuid,
    int segmentIndex,
  ) async {
    final repo = LocalDomainRepository(deps.store, writer: deps.writer, now: now);
    final seed = sourceMessageId ??
        sourceConversationUuid ??
        now().toUtc().microsecondsSinceEpoch.toString();
    // The segment index disambiguates several readings of the SAME type in one
    // turn ("122 …, y de mi esposa 120 …" → two blood_pressure entries) while
    // keeping the write idempotent: a retry of the same message reuses the same
    // per-segment ids instead of duplicating.
    final entryId = 'chat:$seed:${parsed.type}:$segmentIndex';
    final entry = await repo.create(
      parsed.domainKey,
      entryType,
      // The parsed fields become the typed form values; `ts` defaults to now().
      <String, Object?>{...parsed.fields},
      entryId: entryId,
      subject: parsed.subject,
      label: parsed.title,
      extraData: <String, Object?>{
        'raw_utterance': userText.trim(),
        ...provenance,
      },
    );
    return deps.store.getNodeByUuid(entry.uuid);
  }

  /// Write one NON-health clause as a graph fact on the correct hub, routed to a
  /// deterministic domain when the signal is clear (exercise verbs → exercise,
  /// "recé …" → spirituality…), stamped occurred_at = now and attributed to the
  /// clause's resolved subject. Clauses with no save-worthy signal (no domain,
  /// no personal-recall vocabulary, no family subject) are skipped — the model
  /// extractor is the catch-all for open-ended content. Best-effort indexing
  /// follows so the fact is semantically recallable.
  ///
  /// Returns the [CaptureEntry] to CONFIRM to the user (null when the clause
  /// landed without a domain, which has no `Anotado en <Dominio>` to claim),
  /// plus whether a DOMAINLESS fact was really written — so the turn can still
  /// be acknowledged instead of saved in silence.
  Future<({CaptureEntry? entry, bool domainlessWrite})> _captureSegmentFact(
    ChatContextDeps deps,
    UtteranceSegment seg,
    Map<String, Object?> provenance,
  ) async {
    const ({CaptureEntry? entry, bool domainlessWrite}) nothing =
        (entry: null, domainlessWrite: false);
    final text = seg.text.trim();
    if (text.isEmpty) return nothing;
    var domain = router.routeDomain(text);
    if (domain == null &&
        seg.subject == null &&
        !looksLikePersonalRecall(text)) {
      return nothing; // no deterministic signal → leave it to the model complement.
    }
    // A clause the user attributed to a PERSON already has a shelf, even when
    // no domain keyword fired: "Mi hermana Tere vive en Monterrey" is a note
    // about that relationship. It used to land with domain null — invisible in
    // "Mi vida" AND unannounceable — which is the same reasoning [rememberKinship]
    // states out loud: a memory you cannot see is one you cannot correct.
    //
    // EXCEPT a medical shape the parser could not fully own ("de mi esposa
    // 120/80"): a blood-pressure reading under "Relaciones" is a misfile, and a
    // misfile is worse than an unfiled entry.
    if (domain == null && seg.subject != null && !isLoggedVital(text)) {
      domain = 'relationships';
    }
    final label = renderLabel(rawUtterance: text) ?? text;
    final node = await deps.writer.writeFact(
      domain: domain,
      label: label,
      subject: seg.subject,
      // Every extracted fact is stamped occurred_at = now so recall and the
      // deterministic prediction layer can place it in time.
      occurredAt: now(),
      data: <String, dynamic>{'raw_utterance': text, ...provenance},
    );
    await _indexIfPossible(deps, node);
    // `writeFact` returns null for a low-value label: nothing landed, so there
    // is nothing to acknowledge either.
    if (domain == null) return (entry: null, domainlessWrite: node != null);
    return (
      entry: CaptureEntry(domainKey: domain, title: label, subject: seg.subject),
      domainlessWrite: false,
    );
  }

  /// Best-effort RAG indexing of a freshly-written fact node, disposing the
  /// embedder afterwards (RAM load-around-the-turn). A no-op when there is no
  /// node or no embedder.
  Future<void> _indexIfPossible(ChatContextDeps deps, GraphNodeRecord? node) async {
    final rag = deps.rag;
    if (node == null || rag == null) return;
    try {
      await rag.indexNode(node);
    } catch (_) {
      // Embedding backend unavailable — the fact is still lexically recallable.
    } finally {
      await _safeDispose(rag);
    }
  }

  // ── Retrieval ─────────────────────────────────────────────────────────────

  /// Gather candidate memory facts for [message] and map them to [RecallFact]s.
  /// Only `fact` nodes are considered (conversation/person nodes are not
  /// memories to cite). When the message routes to a domain, facts from a
  /// DIFFERENT domain are dropped, but domainless facts (identity/relationships
  /// stored without a domain) always stay in scope.
  /// Add whatever the graph holds about the NAMES in the message.
  ///
  /// Measured on 842, same session, same memory:
  ///
  ///   "¿quién es Ana?"               -> "Ana es tu esposa."
  ///   "¿qué relación tengo con Ana?" -> "no está registrada"
  ///
  /// The recall for the second question was dominated by "relación" and never
  /// surfaced her. Ana is not a `person` node with an edge — she is inside a
  /// FACT — so looking up only people missed her too. A name in the question is
  /// the strongest signal the user could give about what they want remembered;
  /// spending one lexical query on it is cheap and stops the answer depending
  /// on how the sentence was phrased.
  Future<List<GraphNodeRecord>> _byName(
    ChatContextDeps deps,
    List<GraphNodeRecord> recalled,
    String message, {
    int maxPerName = 4,
  }) async {
    final names = properNounsInMessage(message);
    if (names.isEmpty) return recalled;

    final byUuid = {for (final n in recalled) n.uuid: n};
    for (final name in names) {
      try {
        for (final hit in await deps.store.searchNodes(name, limit: maxPerName)) {
          byUuid.putIfAbsent(hit.uuid, () => hit);
        }
      } catch (_) {
        // A store that cannot answer costs us this name, never the turn.
        continue;
      }
    }
    return byUuid.values.toList();
  }

  /// Store a bond the user just stated, and confirm it.
  ///
  /// "Mi hermana se llama Laura" passed the capture triage and produced no
  /// entry, so nothing was written — and the next turn Axi honestly said it did
  /// not know her. Being told about someone's sister and forgetting is the
  /// plainest failure a memory can have.
  ///
  /// Writes BOTH: the person hub (so the bond is a real edge in the graph and
  /// the 3D brain draws it) and a readable fact (so recall can quote it).
  /// Returns the acknowledgment, or null when nothing could be stored — the
  /// caller then lets the model answer rather than claiming a save that did not
  /// happen.
  Future<String?> rememberKinship({
    required String bond,
    required String name,
  }) async {
    try {
      final deps = await loadDeps();
      if (deps == null) return null;
      await deps.writer.learnPersonName(bond, name: name);
      await deps.writer.writeFact(
        // 'relationships', never null: a fact with no domain belongs to no
        // category, so it never appears in "Mi vida" — the user could be told
        // "Anotado" and then find nothing anywhere. A memory you cannot see is
        // one you cannot correct.
        domain: 'relationships',
        label: languageCode() == 'en'
            ? 'your $bond is called $name'
            : 'tu $bond se llama $name',
        subject: bond,
      );
      return languageCode() == 'en'
          ? 'Noted: your $bond is $name.'
          : 'Anotado: tu $bond es $name.';
    } catch (_) {
      return null;
    }
  }

  /// Store what was just said about a person, and acknowledge it in their own
  /// terms.
  ///
  /// The value of this feature lives two months from now, at a dinner: knowing
  /// that Juan's son Mateo is 8 is what makes someone feel remembered. So the
  /// acknowledgement repeats the DETAIL back — if Axi says "anotado" and got
  /// the name wrong, the user finds out now instead of in front of Juan.
  ///
  /// Returns null when nothing was written, so the caller falls through to the
  /// model rather than claiming a save that did not happen.
  Future<String?> rememberPersonFacts(List<PersonFact> facts) async {
    if (facts.isEmpty) return null;
    try {
      final deps = await loadDeps();
      if (deps == null) return null;

      final lines = describePersonFacts(facts);
      for (final line in lines) {
        await deps.writer.writeFact(
          domain: 'relationships',
          label: line,
          subject: facts.first.subject,
        );
      }
      return 'Anotado: ${lines.join(' ')}';
    } catch (_) {
      return null;
    }
  }

  /// Replace the most recent fact about the current subject with [corrected].
  ///
  /// A correction REPLACES; it never adds. Left to the ordinary capture path,
  /// "no, Mateo tiene 9" became a second entry beside "Mateo tiene 8", and
  /// recall could then return either — which is worse than the original error,
  /// because now the memory contradicts itself.
  ///
  /// Returns null when there is nothing to correct, so the caller can say so
  /// instead of inventing a new fact out of a denial.
  Future<String?> applyCorrection(String corrected, {String? subject}) async {
    try {
      final deps = await loadDeps();
      if (deps == null) return null;

      // The newest fact that mentions the subject — that is what a person means
      // by "no, ...": the thing they just said, not something from last month.
      final candidates = subject == null || subject.isEmpty
          ? await deps.store.listNodesByKind('fact', limit: 1)
          : await deps.store.searchNodes(subject, limit: 5);
      final target = candidates
          .where((n) => n.kind == 'fact' && !n.isDeleted)
          .firstOrNull;
      if (target == null) return null;

      await deps.store.softDeleteNode(target.uuid);
      await deps.writer.writeFact(
        domain: target.domain ?? 'relationships',
        label: corrected,
        subject: subject,
      );
      return 'Corregido: $corrected';
    } catch (_) {
      return null;
    }
  }

  /// Answer "¿a qué hora…?" straight from the record, or null.
  ///
  /// Measured on the test Pixel with 881: asked what time he weighed himself,
  /// the model answered 15:16 for a fact recorded at 09:16 — a blend of two
  /// entries' digits. Handing a small model a specific value and hoping it
  /// copies it exactly is a bet this project has lost three times now.
  ///
  /// A wrong hour is not a rounding error: "te tomaste la pastilla a las
  /// 15:00" when it was 09:00 is something a person acts on.
  Future<String?> answerWhenAsked(String question) async {
    if (!asksAboutTime(question)) return null;
    try {
      final deps = await loadDeps();
      if (deps == null) return null;
      final window = parseQueryDateRange(question, now: _wallNow());
      final nodes = await deps.store.listNodesByKind('fact', limit: 60);
      final facts = <TimedFact>[
        for (final node in nodes)
          if (node.occurredAt != null &&
              node.label.trim().isNotEmpty &&
              (window == null || window.contains(node.occurredAt!)))
            (label: node.label.trim(), at: node.occurredAt!),
      ];
      return answerAboutTime(
        question: question,
        facts: facts,
        languageCode: languageCode(),
        location: zoneLocation?.call(),
      );
    } catch (_) {
      return null;
    }
  }

  /// The remembered lines that mention [name], already in the second person.
  ///
  /// Used by the deterministic kinship answer, which reads the bond straight
  /// out of them rather than asking a ~2B model to.
  Future<List<String>> factsMentioning(String name) async {
    try {
      final deps = await loadDeps();
      if (deps == null) return const [];
      final hits = await deps.store.searchNodes(name, limit: 8);
      return [
        for (final n in hits)
          if (n.kind == 'fact' && n.label.trim().isNotEmpty)
            toSecondPerson(n.label),
      ];
    } catch (_) {
      // No memory read is worth losing the turn: an empty list makes the
      // caller fall through to the model.
      return const [];
    }
  }

  /// The `fact` half of a recall. Split out so ONE recall feeds both the facts
  /// and the bonds — recalling twice would double the cost and could return
  /// different sets, leaving a person in the block whose relationships were
  /// gathered from a different search.
  List<RecallFact> _factsFrom(
    List<GraphNodeRecord> nodes,
    String message, {
    Set<String> exemptFromDomain = const {},
  }) {
    final graphDomain = graphDomainForKey(router.routeDomain(message));
    final askedNames = properNounsInMessage(message)
        .map((n) => n.toLowerCase())
        .toSet();
    final facts = <RecallFact>[];
    for (final n in nodes) {
      // Nodes that are not `fact` used to be dropped here, silently — which is
      // why a RELATIONSHIP could never be answered. The bond lives on the
      // EDGES, the 3D brain draws it, and the prompt never saw it:
      // "¿qué relación tengo con Ana?" replied "no está en la memoria" with the
      // edge sitting right there. Their bonds are gathered separately, in
      // `_relationshipsFor`.
      if (n.kind != 'fact') continue;
      if (graphDomain != null &&
          n.domain != null &&
          n.domain != graphDomain &&
          !exemptFromDomain.contains(n.uuid)) {
        // Measured on 843: "¿qué relación tengo con Ana?" still answered "no
        // está registrada" while "¿quién es Ana?" answered correctly. The fact
        // WAS found by name and then discarded here, because the router had
        // routed the question to a different domain. A routing guess must not
        // outrank the user naming somebody.
        continue;
      }
      // A fact about a DIFFERENT person never reaches a question about this one.
      //
      // Measured, repeatedly: asked about someone with nothing stored, the model
      // took the only person-fact in the block and attached it to them —
      // "Mariana es tu esposa" about a name it had never seen. Four rounds of
      // prompt rules made it better, then worse, then worse again: a ~2B model
      // will not reliably police attribution, and every rule added to make it
      // try broke one that already worked.
      //
      // So the block simply never carries the material for that mistake.
      if (askedNames.isNotEmpty && _mentionsAnotherPerson(n.label, askedNames)) {
        continue;
      }
      facts.add(RecallFact(
        // Rewritten to the second person HERE, once, before anything sees it.
        // The memory holds the user's own words ("Sofía es mi hija") and a ~2B
        // model repeating them produced "Eres mi hija Sofia" — Axi claiming the
        // user as its daughter, with the prompt rule already forbidding it.
        label: toSecondPerson(n.label),
        occurredAt: n.occurredAt,
        createdAt: n.createdAt,
        domain: n.domain,
        subject: n.data['subject'] as String?,
      ));
    }
    return facts;
  }

  /// The BONDS of every person among the recalled nodes, as plain sentences.
  ///
  /// Best-effort and bounded: a person with fifty edges must not crowd the
  /// prompt, and a store that cannot answer must not take the whole turn down
  /// with it — an unavailable bond is worth less than a working reply.
  Future<List<String>> _relationshipsFor(
    ChatContextDeps deps,
    List<GraphNodeRecord> nodes,
    String message, {
    int maxPeople = 4,
    int maxPerPerson = 3,
  }) async {
    final lines = <String>[];
    final byUuid = <String, GraphNodeRecord>{
      for (final n in nodes)
        if (n.kind == 'person' && n.label.trim().isNotEmpty) n.uuid: n,
    };

    // Also look people up BY NAME straight from the message.
    //
    // Measured on 841: "¿quién es Ana?" recalled the person and answered "Ana
    // es tu esposa", while "¿qué relación tengo con Ana?" did not — the recall
    // was dominated by "relación" and never surfaced her. A bond reachable only
    // when the question happens to be phrased around the name is a feature that
    // works by luck.
    for (final name in properNounsInMessage(message)) {
      if (byUuid.length >= maxPeople) break;
      try {
        for (final hit in await deps.store.searchNodes(name, limit: 3)) {
          if (hit.kind != 'person' || hit.label.trim().isEmpty) continue;
          byUuid.putIfAbsent(hit.uuid, () => hit);
        }
      } catch (_) {
        continue;
      }
    }

    final people = byUuid.values.take(maxPeople);

    for (final person in people) {
      try {
        final edges = await deps.store.edgesForNode(person.uuid);
        var used = 0;
        for (final edge in edges) {
          if (used >= maxPerPerson) break;
          final bond = edge.relation.trim();
          if (bond.isEmpty) continue;
          lines.add(describeRelationship(
            subject: bond,
            personLabel: person.label,
            languageCode: languageCode(),
          ));
          used++;
        }
        if (used == 0) {
          // Named but with no bond stored. Still worth saying: the model can
          // then answer "sé quién es, no cómo se relacionan" instead of
          // inventing a link.
          lines.add(describeRelationship(
            subject: null,
            personLabel: person.label,
            languageCode: languageCode(),
          ));
        }
      } catch (_) {
        continue;
      }
    }
    return lines;
  }

  /// Semantic recall first (embedder permitting), LEXICAL fallback otherwise.
  /// Disposes the embedder right after embedding so the LLM is the only hot
  /// model at generation time (RAM load-around-the-turn).
  Future<List<GraphNodeRecord>> _recallNodes(
    ChatContextDeps deps,
    String message,
  ) async {
    final rag = deps.rag;
    if (rag != null) {
      try {
        final hits = await rag.recallByText(message, k: recallK);
        await _safeDispose(rag);
        if (hits.isNotEmpty) return hits;
        // Nothing indexed yet → try the lexical index too.
      } catch (_) {
        // Embedding backend not registered / embed failed → lexical fallback.
        await _safeDispose(rag);
      }
    }
    return _lexicalRecall(deps.store, message);
  }

  /// Keyword search fallback: split [message] into content terms, search each
  /// over the store, then rank nodes by how many distinct terms hit (recency
  /// breaks ties). Works with NO embedder at all.
  Future<List<GraphNodeRecord>> _lexicalRecall(
    LocalGraphStore store,
    String message,
  ) async {
    final terms = _keywords(message);
    if (terms.isEmpty) return const [];
    final byUuid = <String, GraphNodeRecord>{};
    final hits = <String, int>{};
    for (final term in terms) {
      for (final n in await store.searchNodes(term, limit: 20)) {
        byUuid[n.uuid] = n;
        hits[n.uuid] = (hits[n.uuid] ?? 0) + 1;
      }
    }
    final ranked = byUuid.values.toList()
      ..sort((a, b) {
        final byHits = hits[b.uuid]!.compareTo(hits[a.uuid]!);
        if (byHits != 0) return byHits;
        return b.createdAt.compareTo(a.createdAt);
      });
    return ranked.take(recallK).toList();
  }

  /// Lowercased content tokens (length > 2, not a stopword), de-duplicated —
  /// the query terms for the lexical fallback. Accents are KEPT on the token
  /// (the store's `searchNodes` is a raw substring match against the original,
  /// accented label, so a folded term would miss "presión"); only the stopword
  /// check folds, so "esta"/"está" are both filtered.
  static List<String> _keywords(String message) {
    final lower = message.toLowerCase();
    final seen = <String>{};
    final out = <String>[];
    for (final raw in lower.split(RegExp(r'''[\s.,;:!?¿¡"'`()\[\]{}<>/\\|@#*_+=~-]+'''))) {
      final tok = raw.trim();
      if (tok.length <= 2) continue;
      if (_stopwords.contains(foldAccents(tok))) continue;
      if (seen.add(tok)) out.add(tok);
    }
    return out;
  }

  // ── Write heuristics ──────────────────────────────────────────────────────

  /// True when [text] reads as a personal STATEMENT worth saving: NOT a question,
  /// NOT an order given to Axi, AND it either carries personal-recall vocabulary
  /// or routes to a domain.
  bool _looksLikeStatement(String text) {
    if (text.trim().isEmpty) return false;
    if (_isQuestion(text)) return false;
    if (_isCommand(text)) return false;
    return looksLikePersonalRecall(text) || router.routeDomain(text) != null;
  }

  /// Cheap question detector: a question mark anywhere, or a leading
  /// interrogative word (ES/EN). A recall QUESTION must not be saved as a fact.
  static bool _isQuestion(String text) {
    final t = text.trim();
    if (t.contains('?') || t.contains('¿')) return true;
    final folded = foldAccents(t.toLowerCase());
    final first = folded.split(RegExp(r'\s+')).first;
    return _interrogatives.contains(first);
  }

  /// Cheap ORDER detector: a leading imperative addressed to Axi.
  ///
  /// Measured on the Pixel: "Cuenta del 1 al 30 separados por comas" was
  /// answered "Anotado en Finanzas: …" and left a permanent finance record.
  /// The gate only knew two shapes, question and statement, and an order is
  /// neither: it describes a TASK, not something that happened to the user.
  ///
  /// The verb list lives in `order_to_axi.dart` because the conversation
  /// SUBJECT needs the same reading — see [looksLikeOrderToAxi].
  static bool _isCommand(String text) => looksLikeOrderToAxi(text);

  static const Set<String> _interrogatives = <String>{
    'que', 'como', 'cuando', 'donde', 'quien', 'quienes', 'cual', 'cuales',
    'cuanto', 'cuanta', 'cuantos', 'cuantas', 'por', 'sabes', 'recuerdas',
    'what', 'how', 'when', 'where', 'who', 'which', 'why', 'whose',
    'do', 'does', 'did', 'can', 'could', 'is', 'are', 'was', 'were', 'remember',
  };

  static const Set<String> _stopwords = <String>{
    // ES
    'que', 'con', 'por', 'para', 'los', 'las', 'una', 'uno', 'del', 'mas',
    'pero', 'como', 'esta', 'este', 'esto', 'esos', 'esas', 'son', 'fue',
    'era', 'hoy', 'ayer', 'muy', 'sin', 'sus', 'nos',
    // EN
    'the', 'and', 'for', 'with', 'was', 'were', 'have', 'has', 'had', 'you',
    'your', 'his', 'her', 'their', 'this', 'that', 'these', 'those', 'about',
    'from', 'are', 'but', 'not', 'been', 'what', 'how', 'when', 'who', 'why',
  };

  static Future<void> _safeDispose(RagService rag) async {
    try {
      await rag.embedder.dispose();
    } catch (_) {
      // A dispose failure must never break the turn.
    }
  }
}

/// Words in [message] that look like someone's NAME.
///
/// Capitalised, not the first word (where anything is), and not a known
/// question opener. Crude on purpose: the result is only used to LOOK UP a
/// person, so a false positive costs one query that finds nothing, while a
/// false negative costs the user an answer.
List<String> properNounsInMessage(String message) {
  const openers = {
    'Que', 'Qué', 'Quien', 'Quién', 'Como', 'Cómo', 'Cuando', 'Cuándo',
    'Donde', 'Dónde', 'Cual', 'Cuál', 'Cuanto', 'Cuánto', 'Por', 'Para',
    'What', 'Who', 'When', 'Where', 'Which', 'How', 'Why', 'The', 'My',
  };
  final words = message.split(RegExp(r'[^\p{L}]+', unicode: true))
    ..removeWhere((w) => w.isEmpty);
  return [
    for (var i = 0; i < words.length; i++)
      if (i > 0 &&
          words[i].length > 2 &&
          words[i][0].toUpperCase() == words[i][0] &&
          words[i][0].toLowerCase() != words[i][0] &&
          !openers.contains(words[i]))
        words[i],
  ];
}

/// True when [label] names a person and NONE of them is one of [askedNames].
///
/// Facts that name nobody (a weight, a blood pressure, an appointment) always
/// pass: they are not attributable to the wrong person because they are not
/// about a person at all.
bool _mentionsAnotherPerson(String label, Set<String> askedNames) {
  final lower = label.toLowerCase();

  // Mentions the person asked about: always keep it.
  if (askedNames.any(lower.contains)) return false;

  // Does it talk about a PERSON at all? Two signals, because either alone
  // leaks: a capitalised name catches "Ana", and a kinship word catches
  // "mi esposa se llama ana" — which is exactly the line that slipped through
  // when only names were checked, and let "Mariana es tu esposa" survive.
  const kinship = {
    'esposa', 'esposo', 'marido', 'mujer', 'hija', 'hijo', 'madre', 'padre',
    'mamá', 'papá', 'hermana', 'hermano', 'novia', 'novio', 'jefe', 'jefa',
    'colega', 'amiga', 'amigo', 'suegra', 'suegro', 'tía', 'tío', 'prima',
    'primo', 'abuela', 'abuelo', 'nieta', 'nieto', 'cuñada', 'cuñado',
    'wife', 'husband', 'daughter', 'son', 'mother', 'father', 'sister',
    'brother', 'boss', 'colleague', 'friend', 'girlfriend', 'boyfriend',
  };
  final aboutSomeone = properNounsInMessage('x $label').isNotEmpty ||
      kinship.any((k) => RegExp('(?<![\\p{L}])$k(?![\\p{L}])', unicode: true)
          .hasMatch(lower));

  // Facts about nobody — a weight, a blood pressure, an appointment — always
  // pass: they cannot be attributed to the wrong person.
  return aboutSomeone;
}
