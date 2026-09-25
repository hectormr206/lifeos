// Reading one passage: tap a word, see what it means here, keep it.
//
// The passage is shown exactly as written, with every word tappable. Words the
// placement says are probably new are underlined BEFORE anyone taps: drawing
// attention to a form helps it get noticed and learned (textual enhancement),
// and it tells the learner at a glance that there are only a few.
//
// A tap asks the on-device model what the word means in THAT sentence. When
// the model cannot answer, the sheet says so instead of guessing. "Guardar
// para repasar" keeps the dictionary form with the sentence and its source,
// which is what the review will show. The source is credited under the text,
// as CC BY-SA requires.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../data/wikimedia_reading.dart';
import '../data/word_gloss.dart';
import '../domain/lexical_coverage.dart';
import '../domain/reader_tokens.dart';
import 'english_providers.dart';

class EnglishReaderScreen extends ConsumerStatefulWidget {
  const EnglishReaderScreen({super.key, required this.reading});

  final PickedReading reading;

  @override
  ConsumerState<EnglishReaderScreen> createState() =>
      _EnglishReaderScreenState();
}

class _EnglishReaderScreenState extends ConsumerState<EnglishReaderScreen> {
  late final List<ReaderToken> _tokens =
      readerTokens(widget.reading.ranked.passage.text);
  late final Map<int, TapGestureRecognizer> _taps = {
    for (var i = 0; i < _tokens.length; i++)
      if (_tokens[i].isWord) i: TapGestureRecognizer()..onTap = () => _open(i),
  };

  @override
  void dispose() {
    for (final tap in _taps.values) {
      tap.dispose();
    }
    super.dispose();
  }

  void _open(int i) {
    final token = _tokens[i];
    final index = ref.read(wordIndexProvider).value;
    final article = widget.reading.article;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _GlossSheet(
        word: token.text,
        lemma: index?.lemmaOf(token.text) ?? token.text.toLowerCase(),
        context: SavedContext(
          sentence: token.sentence,
          source: '${article.site}/${article.title}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final reading = widget.reading;
    final report = reading.ranked.report;
    final index = ref.watch(wordIndexProvider).value;
    final unknown = report.unknownLemmas.toSet();
    bool isNew(String word) =>
        unknown.contains(index?.lemmaOf(word) ?? word.toLowerCase());

    return Scaffold(
      appBar: AppBar(title: Text(reading.article.title)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            l10n.englishFitLine(
              _fitLabel(l10n, report.fit),
              (report.coverage * 100).round(),
            ),
            style: theme.textTheme.labelLarge,
          ),
          if (reading.ranked.passage.section.isNotEmpty)
            Text(reading.ranked.passage.section,
                style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(l10n.englishReaderHint, style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          Text.rich(
            TextSpan(
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
              children: [
                for (var i = 0; i < _tokens.length; i++)
                  TextSpan(
                    text: _tokens[i].text,
                    recognizer: _taps[i],
                    style: _tokens[i].isWord && isNew(_tokens[i].text)
                        ? const TextStyle(decoration: TextDecoration.underline)
                        : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            l10n.englishReaderCredit(
              reading.article.title,
              reading.article.site,
              reading.article.license,
            ),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

String _fitLabel(AppLocalizations l10n, TextFit fit) => switch (fit) {
      TextFit.easy => l10n.englishFitEasy,
      TextFit.atLevel => l10n.englishFitAtLevel,
      TextFit.hard || TextFit.empty => l10n.englishFitHard,
    };

enum _Save { idle, saved, failed }

class _GlossSheet extends ConsumerStatefulWidget {
  const _GlossSheet({
    required this.word,
    required this.lemma,
    required this.context,
  });

  final String word;
  final String lemma;
  final SavedContext context;

  @override
  ConsumerState<_GlossSheet> createState() => _GlossSheetState();
}

class _GlossSheetState extends ConsumerState<_GlossSheet> {
  late final Future<String?> _gloss = ref
      .read(wordGlosserProvider)
      .gloss(word: widget.word, sentence: widget.context.sentence);
  _Save _save = _Save.idle;

  Future<void> _keep(String? gloss) async {
    try {
      final saver = await ref.read(wordSaverProvider.future);
      await saver.save(
        lemma: widget.lemma,
        gloss: gloss,
        context: widget.context,
      );
      if (mounted) setState(() => _save = _Save.saved);
    } catch (_) {
      if (mounted) setState(() => _save = _Save.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final lemma = widget.lemma != widget.word.toLowerCase()
        ? ' → ${widget.lemma}'
        : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: FutureBuilder<String?>(
        future: _gloss,
        builder: (context, snapshot) {
          final done = snapshot.connectionState == ConnectionState.done;
          final gloss = snapshot.data;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${widget.word}$lemma', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(widget.context.sentence,
                  style: const TextStyle(fontStyle: FontStyle.italic)),
              const SizedBox(height: 16),
              if (!done)
                Text(l10n.englishReaderLooking)
              else if (gloss == null)
                Text(l10n.englishReaderNoGloss)
              else
                Text(gloss, style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              switch (_save) {
                _Save.saved => Text(l10n.englishReaderSaved),
                _Save.failed => Text(
                    l10n.englishReaderSaveFailed,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                _Save.idle => FilledButton(
                    onPressed: done ? () => _keep(gloss) : null,
                    child: Text(l10n.englishReaderSave),
                  ),
              },
            ],
          );
        },
      ),
    );
  }
}
