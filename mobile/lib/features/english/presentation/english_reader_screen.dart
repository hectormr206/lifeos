// Reading one passage: tap a word, see what it means here, keep it.
//
// The passage is shown exactly as written, with every word tappable. Words the
// placement says are probably new are underlined BEFORE anyone taps: drawing
// attention to a form helps it get noticed and learned (textual enhancement),
// and it tells the learner at a glance that there are only a few.
//
// "Escuchar" reads it aloud with one of the installed English voices, sentence
// by sentence, highlighting the sentence being spoken; "Más lento" slows it to
// the learner pace. With no English voice installed it says how to get one.
//
// A tap asks the on-device model what the word means in THAT sentence. When
// the model cannot answer, the sheet says so instead of guessing. "Guardar
// para repasar" keeps the dictionary form with the sentence and its source,
// which is what the review will show. The source is credited under the text,
// as CC BY-SA requires.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../data/passage_speaker.dart';
import '../data/wikimedia_reading.dart';
import '../data/word_gloss.dart';
import '../domain/lexical_coverage.dart';
import '../domain/reader_tokens.dart';
import 'english_providers.dart';
import 'english_speak_screen.dart';

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

  /// The sentences of the passage, in order, each once.
  late final List<String> _sentences = <String>{
    for (final t in _tokens)
      if (t.isWord && t.sentence.isNotEmpty) t.sentence,
  }.toList();

  /// The sentence being spoken, or null when not listening.
  String? _speaking;
  bool _listening = false;
  bool _slow = false;
  StreamSubscription<int>? _speech;

  @override
  void dispose() {
    for (final tap in _taps.values) {
      tap.dispose();
    }
    // The provider stops the speaker when it is disposed with this screen;
    // the subscription is only released here, never awaited.
    unawaited(_speech?.cancel());
    super.dispose();
  }

  Future<void> _listen() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.maybeOf(context);
    final voices = await ref.read(installedEnglishVoicesProvider.future);
    final text = widget.reading.ranked.passage.text;
    final id = pickEnglishVoice(
      voices.keys.toList(),
      seed: text.codeUnits.fold(0, (h, c) => (h * 31 + c) & 0x7fffffff),
    );
    if (!mounted) return;
    if (id == null) {
      messenger.showSnackBar(SnackBar(
        content: Text(l10n.englishListenNoVoice),
        action: router == null
            ? null
            : SnackBarAction(
                label: l10n.englishListenGetVoice,
                onPressed: () => router.push('/settings/voice/catalog'),
              ),
      ));
      return;
    }
    setState(() => _listening = true);
    _speech = ref
        .read(passageSpeakerProvider)
        .speak(_sentences, voice: voices[id]!, speed: _slow ? kSlowSpeed : 1.0)
        .listen(
          (i) => setState(() => _speaking = _sentences[i]),
          onError: (Object _) {
            messenger.showSnackBar(
                SnackBar(content: Text(l10n.englishListenFailed)));
            _stopped();
          },
          onDone: _stopped,
        );
  }

  void _stopped() {
    if (mounted) {
      setState(() {
        _listening = false;
        _speaking = null;
      });
    }
  }

  /// The speaker is stopped FIRST: cancelling an `async*` stream waits for it
  /// to leave its current await, and that await is waiting for the stop. The
  /// other order deadlocks (the test caught it).
  Future<void> _stop() async {
    await ref.read(passageSpeakerProvider).stop();
    await _speech?.cancel();
    _stopped();
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

    final highlight = theme.colorScheme.secondaryContainer;
    // Watched, not just read: the speaker is autoDispose, and only a watch
    // keeps it (and its player) alive while this reader is open. With `read`
    // alone Riverpod could release it mid-sentence. Its onDispose stops the
    // voice when the reader closes.
    ref.watch(passageSpeakerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(reading.article.title),
        actions: [
          IconButton(
            tooltip: l10n.englishSpeakTitle,
            icon: const Icon(Icons.record_voice_over),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => EnglishSpeakScreen(
                text: reading.ranked.passage.text,
                source: '${reading.article.site}/${reading.article.title}',
              ),
            )),
          ),
          IconButton(
            tooltip: l10n.englishListenSlow,
            isSelected: _slow,
            icon: const Icon(Icons.slow_motion_video),
            onPressed: () => setState(() => _slow = !_slow),
          ),
          IconButton(
            tooltip: _listening ? l10n.englishListenStop : l10n.englishListen,
            icon: Icon(_listening ? Icons.stop : Icons.volume_up),
            onPressed: _listening ? _stop : _listen,
          ),
        ],
      ),
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
                    style: TextStyle(
                      decoration: _tokens[i].isWord && isNew(_tokens[i].text)
                          ? TextDecoration.underline
                          : null,
                      backgroundColor: _tokens[i].isWord &&
                              _tokens[i].sentence == _speaking
                          ? highlight
                          : null,
                    ),
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
