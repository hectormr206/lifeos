// Reading aloud: listen, say it, see which words came through.
//
// One sentence at a time from the passage just read. "Escuchar" says it with
// an English voice; the learner repeats along or right after (shadowing, which
// helps fluency and prosody) or reads it first on their own. "Grabar" records
// through the same sealed, encrypted voice-note path as the chat, Whisper
// transcribes it as English, and each word of the sentence shows whether it
// came through. Every attempt goes to the archive, so month one can be heard
// next to month three.
//
// The screen says plainly what the score is NOT: a pronunciation grade.
// Whisper leans towards the right words when the text is known.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/chat_providers.dart';
import '../../stt/presentation/stt_providers.dart';
import '../data/passage_speaker.dart';
import '../data/recordings_repository.dart';
import '../domain/read_aloud_score.dart';
import '../domain/reader_tokens.dart';
import '../data/activity_log.dart';
import '../domain/daily_plan.dart';
import 'english_providers.dart';

/// Sentences worth reading aloud: long enough to say something, short enough
/// to hold in the ear after one listen (and well inside Whisper's 30-second
/// window). At most a handful per passage.
List<String> practiceSentences(String text) {
  final all = <String>{
    for (final t in readerTokens(text))
      if (t.isWord && t.sentence.isNotEmpty) t.sentence,
  };
  return [
    for (final s in all)
      if (_wordCount(s) >= 4 && _wordCount(s) <= 25) s,
  ].take(6).toList();
}

int _wordCount(String s) => readerTokens(s).where((t) => t.isWord).length;

enum _Phase { idle, recording, transcribing, scored, failed }

class EnglishSpeakScreen extends ConsumerStatefulWidget {
  const EnglishSpeakScreen({
    super.key,
    required this.text,
    required this.source,
  });

  final String text;

  /// Where the passage came from, kept with each attempt.
  final String source;

  @override
  ConsumerState<EnglishSpeakScreen> createState() => _EnglishSpeakScreenState();
}

class _EnglishSpeakScreenState extends ConsumerState<EnglishSpeakScreen> {
  late final List<String> _sentences = practiceSentences(widget.text);
  int _index = 0;
  _Phase _phase = _Phase.idle;
  String? _problem;
  ReadAloudScore? _score;
  String _heard = '';

  String get _sentence => _sentences[_index];

  late final ActivityTimer _timer =
      ActivityTimer(ActivityKind.speak, ref.read(activityLogProvider.future));
  bool _recordedAny = false;

  @override
  void initState() {
    super.initState();
    _timer; // starts the clock when the screen opens
  }

  @override
  void dispose() {
    if (_recordedAny) _timer.finish();
    super.dispose();
  }

  Future<void> _listen() async {
    final voices = await ref.read(installedEnglishVoicesProvider.future);
    final id = pickEnglishVoice(voices.keys.toList(), seed: _index);
    if (id == null || !mounted) return;
    await ref
        .read(passageSpeakerProvider)
        .speak([_sentence], voice: voices[id]!, speed: kSlowSpeed)
        .drain<void>();
  }

  Future<void> _record() async {
    final l10n = AppLocalizations.of(context);
    final recorder = ref.read(audioRecorderGatewayProvider);
    if (!await recorder.hasPermission()) {
      setState(() => _problem = l10n.englishSpeakNoMic);
      return;
    }
    await recorder.start();
    setState(() {
      _phase = _Phase.recording;
      _problem = null;
    });
  }

  Future<void> _finish() async {
    final l10n = AppLocalizations.of(context);
    final path = await ref.read(audioRecorderGatewayProvider).stop();
    if (path == null) return;
    setState(() => _phase = _Phase.transcribing);
    try {
      final heard = await ref
          .read(speechToTextProvider)
          .transcribe(path, languageCode: 'en');
      final score = scoreReadAloud(target: _sentence, transcript: heard);
      final archive = await ref.read(recordingArchiveProvider.future);
      await archive.save(Recording(
        sentence: _sentence,
        source: widget.source,
        transcript: heard,
        intelligibility: score.intelligibility,
        audioPath: path,
        recordedAt: DateTime.now(),
      ));
      _recordedAny = true;
      if (mounted) {
        setState(() {
          _phase = _Phase.scored;
          _score = score;
          _heard = heard;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _problem = l10n.englishSpeakSttFailed;
        });
      }
    }
  }

  void _next() => setState(() {
        _index = (_index + 1) % _sentences.length;
        _phase = _Phase.idle;
        _score = null;
        _problem = null;
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final score = _score;
    final error = theme.colorScheme.error;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishSpeakTitle)),
      body: _sentences.isEmpty
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(l10n.englishSpeakHint, style: theme.textTheme.bodySmall),
                const SizedBox(height: 16),
                if (score == null)
                  Text(_sentence, style: theme.textTheme.titleLarge)
                else
                  Text.rich(TextSpan(
                    style: theme.textTheme.titleLarge,
                    children: [
                      for (final w in score.words) ...[
                        TextSpan(
                          text: w.text,
                          style: w.heard
                              ? null
                              : TextStyle(
                                  color: error,
                                  decoration: TextDecoration.underline,
                                ),
                        ),
                        const TextSpan(text: ' '),
                      ],
                    ],
                  )),
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: _phase == _Phase.recording ? null : _listen,
                  child: Text(l10n.englishListen),
                ),
                const SizedBox(height: 8),
                switch (_phase) {
                  _Phase.recording => FilledButton(
                      onPressed: _finish, child: Text(l10n.englishSpeakStop)),
                  _Phase.transcribing => Text(l10n.englishSpeakListening),
                  _ => FilledButton(
                      onPressed: _record, child: Text(l10n.englishSpeakRecord)),
                },
                if (score != null) ...[
                  const SizedBox(height: 16),
                  Text(l10n.englishSpeakScore(
                      (score.intelligibility * 100).round())),
                  Text(l10n.englishSpeakHeard(_heard)),
                  const SizedBox(height: 4),
                  Text(l10n.englishSpeakCaveat, style: theme.textTheme.bodySmall),
                ],
                if (_problem != null) ...[
                  const SizedBox(height: 16),
                  Text(_problem!, style: TextStyle(color: error)),
                ],
                const SizedBox(height: 24),
                TextButton(onPressed: _next, child: Text(l10n.englishSpeakNext)),
              ],
            ),
    );
  }
}
