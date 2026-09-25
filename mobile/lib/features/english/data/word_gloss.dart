// What a tapped word means, and keeping it for review.
//
// A word alone is ambiguous ("bank" by a river or with money, "run" a race or
// a company), so the on-device model is asked what it means IN THE SENTENCE
// being read. It answers in Spanish, briefly: a gloss is a nudge while
// reading, not a dictionary entry. When the model cannot answer, the result
// is null and the screen says so; it never pretends.
//
// A saved word is a graph node of its own kind (not a `fact`: it is study
// material, not a memory), so it is encrypted and follows the learner to
// their other devices. It keeps every different sentence it was met in, up to
// a few, because reviewing a word in a new context each time helps it stick
// (PNAS 2024, "The role of variable retrieval in effective learning").
library;

import 'dart:convert';

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../../local_model/domain/local_llm_engine.dart';
import '../domain/fsrs.dart';

/// A gloss longer than this is cut: it has to fit on a card.
const int kMaxGlossChars = 80;

/// Sentences kept per saved word: enough to vary every review for a while.
const int kMaxSavedContexts = 5;

const String kSavedWordKind = 'english_word';
const String _domain = 'learning';
const int _dataVersion = 1;

String buildGlossPrompt({required String word, required String sentence}) =>
    'You are helping a Spanish speaker read English.\n'
    'Sentence: $sentence\n'
    'Word: "$word"\n'
    'Give the meaning of the word AS USED IN THIS SENTENCE, in neutral '
    'Spanish, in at most six words. Answer with the meaning only, on one '
    'line, with no quotes and no explanation.';

/// The first real line of the model's answer, unquoted and capped; null when
/// there is nothing usable.
String? parseGloss(String answer) {
  for (final raw in const LineSplitter().convert(answer)) {
    final line = raw.trim().replaceAll(RegExp(r'^["“”«»]+|["“”«»]+$'), '').trim();
    if (line.isEmpty) continue;
    return line.length <= kMaxGlossChars
        ? line
        : '${line.substring(0, kMaxGlossChars - 1)}…';
  }
  return null;
}

class WordGlosser {
  WordGlosser(this._engine);

  final LocalLlmEngine _engine;

  /// Low temperature: a meaning, not a creative answer.
  static const double _temperature = 0.2;

  /// Null when the model is missing, fails or says nothing usable.
  Future<String?> gloss({required String word, required String sentence}) async {
    try {
      final result = await _engine.generate(
        buildGlossPrompt(word: word, sentence: sentence),
        temperature: _temperature,
      );
      return parseGloss(result.text);
    } catch (_) {
      return null;
    }
  }
}

/// A sentence a word was met in, and where it came from.
class SavedContext {
  const SavedContext({required this.sentence, required this.source});

  final String sentence;

  /// Site and article, e.g. `simple.wikipedia.org/Food`.
  final String source;

  Map<String, Object?> toJson() => {'sentence': sentence, 'source': source};
}

class SavedWord {
  const SavedWord({
    required this.uuid,
    required this.lemma,
    required this.gloss,
    required this.contexts,
    this.card,
    this.reviews = 0,
    this.firstReviewAt,
  });

  /// The graph node it lives in.
  final String uuid;
  final String lemma;
  final String? gloss;

  /// Oldest first.
  final List<SavedContext> contexts;

  /// Its FSRS memory state; null until the first review.
  final FsrsCard? card;

  /// Reviews so far: also picks which saved sentence the next one shows.
  final int reviews;

  /// When it was first reviewed: new words are capped per day.
  final DateTime? firstReviewAt;
}

/// What the reader needs to keep a word. An interface so the screen can be
/// tested without the encrypted database.
abstract interface class WordSaver {
  Future<void> save({
    required String lemma,
    required String? gloss,
    required SavedContext context,
  });
}

/// What the review needs: the saved words, and a place to record each
/// answer. An interface so the screen can be tested without the database.
abstract interface class ReviewStore {
  Future<List<SavedWord>> all();

  Future<void> recordReview(String uuid, FsrsCard card, {required DateTime at});
}

class SavedWordsRepository implements WordSaver, ReviewStore {
  SavedWordsRepository(this._store);

  final LocalGraphStore _store;

  /// Saves [lemma], or adds [context] to it when it is already saved. A known
  /// gloss is never replaced by a missing one.
  @override
  Future<void> save({
    required String lemma,
    required String? gloss,
    required SavedContext context,
  }) async {
    final existing = await _find(lemma);
    if (existing == null) {
      await _store.createNode(
        kind: kSavedWordKind,
        label: lemma,
        domain: _domain,
        data: _data(gloss: gloss, contexts: [context]),
      );
      return;
    }
    final word = _fromNode(existing)!;
    final contexts = [
      for (final c in word.contexts)
        if (c.sentence != context.sentence) c,
      context,
    ];
    await _store.upsertNode(existing.copyWith(
      data: {
        // Review progress travels with the word: saving it again from a new
        // sentence must never reset what the learner already built.
        ...existing.data,
        ..._data(
          gloss: gloss ?? word.gloss,
          contexts: contexts.length > kMaxSavedContexts
              ? contexts.sublist(contexts.length - kMaxSavedContexts)
              : contexts,
        ),
      },
    ));
  }

  /// Stores the card after a review, counts it, and remembers the first day.
  @override
  Future<void> recordReview(
    String uuid,
    FsrsCard card, {
    required DateTime at,
  }) async {
    final node = await _store.getNodeByUuid(uuid);
    if (node == null) return;
    final word = _fromNode(node);
    await _store.upsertNode(node.copyWith(data: {
      ...node.data,
      'fsrs': _cardToJson(card),
      'reviews': (word?.reviews ?? 0) + 1,
      'firstReviewAt':
          (word?.firstReviewAt ?? at).toUtc().toIso8601String(),
    }));
  }

  @override
  Future<List<SavedWord>> all() async => [
        for (final node in await _store.listNodesByKind(kSavedWordKind))
          ?_fromNode(node),
      ];

  Future<GraphNodeRecord?> _find(String lemma) async {
    for (final node in await _store.listNodesByKind(kSavedWordKind)) {
      if (node.label == lemma && _fromNode(node) != null) return node;
    }
    return null;
  }
}

Map<String, Object?> _data({
  required String? gloss,
  required List<SavedContext> contexts,
}) =>
    {
      // Chosen by a person while reading: any cleanup that reads `source`
      // leaves it alone.
      'source': kSavedWordKind,
      'version': _dataVersion,
      'gloss': gloss,
      'contexts': [for (final c in contexts) c.toJson()],
    };

SavedWord? _fromNode(GraphNodeRecord node) {
  final data = node.data;
  if (data['version'] != _dataVersion) return null;
  final contexts = data['contexts'];
  if (contexts is! List) return null;
  final gloss = data['gloss'];
  final reviews = data['reviews'];
  return SavedWord(
    uuid: node.uuid,
    lemma: node.label,
    gloss: gloss is String ? gloss : null,
    card: _cardFromJson(data['fsrs']),
    reviews: reviews is int ? reviews : 0,
    firstReviewAt: DateTime.tryParse('${data['firstReviewAt']}'),
    contexts: [
      for (final c in contexts)
        if (c is Map && c['sentence'] is String)
          SavedContext(
            sentence: c['sentence'] as String,
            source: '${c['source'] ?? ''}',
          ),
    ],
  );
}

Map<String, Object?> _cardToJson(FsrsCard card) => {
      'state': card.state.name,
      'step': card.step,
      'stability': card.stability,
      'difficulty': card.difficulty,
      'due': card.due.toUtc().toIso8601String(),
      'lastReview': card.lastReview?.toUtc().toIso8601String(),
    };

/// Null for a word never reviewed, or for a card this version cannot read:
/// it then starts over as new rather than being scheduled from garbage.
FsrsCard? _cardFromJson(Object? json) {
  if (json is! Map) return null;
  final state = FsrsState.values.asNameMap()[json['state']];
  final due = DateTime.tryParse('${json['due']}');
  final step = json['step'];
  final stability = json['stability'];
  final difficulty = json['difficulty'];
  if (state == null || due == null) return null;
  return FsrsCard(
    state: state,
    step: step is int ? step : null,
    stability: stability is num ? stability.toDouble() : null,
    difficulty: difficulty is num ? difficulty.toDouble() : null,
    due: due,
    lastReview: DateTime.tryParse('${json['lastReview']}'),
  );
}
