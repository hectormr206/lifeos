// What a tapped word means, and keeping it for review.
//
// A word alone is ambiguous ("bank", "run"), so the on-device model is asked
// what it means IN THE SENTENCE the learner is reading. A saved word keeps
// every different sentence it was met in, up to a few, because reviewing a
// word in a new context each time helps it stick (PNAS 2024, variable
// retrieval).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/english/data/word_gloss.dart';
import 'package:lifeos/features/english/domain/fsrs.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

void main() {
  group('asking what a word means in its sentence', () {
    test('the prompt carries the word and the whole sentence', () {
      final prompt = buildGlossPrompt(
        word: 'bank',
        sentence: 'We sat on the bank of the river.',
      );

      expect(prompt, contains('"bank"'));
      expect(prompt, contains('We sat on the bank of the river.'));
      expect(prompt.toLowerCase(), contains('spanish'));
    });

    test('the answer is its first real line, without quotes', () {
      expect(parseGloss('\n"orilla (de un río)"\nmore text'),
          'orilla (de un río)');
    });

    test('an empty answer is no gloss, not an empty one', () {
      expect(parseGloss('  \n '), isNull);
    });

    test('a rambling answer is cut to something that fits a card', () {
      final gloss = parseGloss('x' * 300)!;
      expect(gloss.length, lessThanOrEqualTo(kMaxGlossChars));
    });

    test('the model failing gives no gloss and does not throw', () async {
      final engine = FakeLocalLlmEngine(generateShouldFail: true);

      final gloss = await WordGlosser(engine).gloss(
        word: 'bank',
        sentence: 'We sat on the bank.',
      );

      expect(gloss, isNull);
    });
  });

  group('keeping words for review', () {
    late Database db;
    late LocalGraphStore store;
    late SavedWordsRepository words;

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await applyLocalGraphSchema(db);
      store = SqfliteLocalGraphStore(db);
      words = SavedWordsRepository(store);
    });

    tearDown(() async => db.close());

    SavedContext context(String sentence) => SavedContext(
          sentence: sentence,
          source: 'simple.wikipedia.org/Food',
        );

    test('a saved word is its own kind of node, under learning', () async {
      await words.save(lemma: 'sniff', gloss: 'olfatear',
          context: context('Dogs sniff the ground.'));

      final node = (await store.listNodesByKind(kSavedWordKind)).single;
      expect(node.label, 'sniff');
      expect(node.domain, 'learning');
      expect(node.data['source'], kSavedWordKind);
    });

    test('saving the same word again adds the new sentence, not a copy',
        () async {
      await words.save(lemma: 'sniff', gloss: 'olfatear',
          context: context('Dogs sniff the ground.'));
      await words.save(lemma: 'sniff', gloss: 'olfatear',
          context: context('The cat sniffed the food.'));

      final saved = await words.all();
      expect(saved, hasLength(1));
      expect(saved.single.contexts.map((c) => c.sentence),
          ['Dogs sniff the ground.', 'The cat sniffed the food.']);
    });

    test('the same sentence twice is kept once', () async {
      for (var i = 0; i < 2; i++) {
        await words.save(lemma: 'sniff', gloss: 'olfatear',
            context: context('Dogs sniff the ground.'));
      }

      expect((await words.all()).single.contexts, hasLength(1));
    });

    test('only the latest few sentences are kept', () async {
      for (var i = 0; i < kMaxSavedContexts + 2; i++) {
        await words.save(lemma: 'sniff', gloss: 'olfatear',
            context: context('Sentence number $i.'));
      }

      final contexts = (await words.all()).single.contexts;
      expect(contexts, hasLength(kMaxSavedContexts));
      expect(contexts.last.sentence, 'Sentence number ${kMaxSavedContexts + 1}.');
    });

    test('a word saved without a gloss keeps a later one', () async {
      await words.save(lemma: 'sniff', gloss: null,
          context: context('Dogs sniff the ground.'));
      await words.save(lemma: 'sniff', gloss: 'olfatear',
          context: context('The cat sniffed.'));

      expect((await words.all()).single.gloss, 'olfatear');
    });
    test('a review is kept with the word: its card, count and first day',
        () async {
      await words.save(lemma: 'sniff', gloss: 'olfatear',
          context: context('Dogs sniff the ground.'));
      final uuid = (await words.all()).single.uuid;
      final at = DateTime.utc(2026, 9, 25, 12);
      final card = FsrsScheduler()
          .review(FsrsCard.newCard(at), FsrsRating.good, at);

      await words.recordReview(uuid, card, at: at);
      await words.recordReview(uuid, card, at: at.add(const Duration(days: 1)));

      final word = (await words.all()).single;
      expect(word.card!.stability, card.stability);
      expect(word.card!.due, card.due);
      expect(word.card!.state, card.state);
      expect(word.reviews, 2);
      expect(word.firstReviewAt, at, reason: 'the first day is set once');
    });

    test('saving a word again never loses its review progress', () async {
      await words.save(lemma: 'sniff', gloss: 'olfatear',
          context: context('Dogs sniff the ground.'));
      final uuid = (await words.all()).single.uuid;
      final at = DateTime.utc(2026, 9, 25, 12);
      await words.recordReview(uuid,
          FsrsScheduler().review(FsrsCard.newCard(at), FsrsRating.good, at),
          at: at);

      await words.save(lemma: 'sniff', gloss: 'olfatear',
          context: context('The cat sniffed.'));

      final word = (await words.all()).single;
      expect(word.card, isNotNull);
      expect(word.reviews, 1);
    });

    test('a word never reviewed has no card yet', () async {
      await words.save(lemma: 'sniff', gloss: null,
          context: context('Dogs sniff.'));

      final word = (await words.all()).single;
      expect(word.card, isNull);
      expect(word.reviews, 0);
    });
  });
}
