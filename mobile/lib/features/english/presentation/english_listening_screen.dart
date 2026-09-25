// The listening placement (graded dictation), as the learner lives it.
//
// One sentence at a time, harder and harder, heard with an English voice at
// its natural pace and at most twice. The learner writes what they
// understood; "Comprobar" shows how much came through and the sentence
// itself, so every item teaches something too. The result is the last level
// passed. "Before A1" is said as the starting point it is, not as a failure,
// and the screen is honest that a clear synthetic voice is easier than
// people. Every attempt is kept.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../data/activity_log.dart';
import '../data/passage_speaker.dart';
import '../domain/daily_plan.dart';
import '../domain/listening_placement.dart';
import 'english_providers.dart';

/// Plays per sentence: a second chance, not a loop.
const int _maxPlays = 2;

class EnglishListeningScreen extends ConsumerStatefulWidget {
  const EnglishListeningScreen({super.key});

  @override
  ConsumerState<EnglishListeningScreen> createState() =>
      _EnglishListeningScreenState();
}

class _EnglishListeningScreenState extends ConsumerState<EnglishListeningScreen> {
  final _session = ListeningPlacement();
  final _typed = TextEditingController();
  late final ActivityTimer _timer =
      ActivityTimer(ActivityKind.placement, ref.read(activityLogProvider.future));
  int _number = 1;
  int _plays = 0;
  double? _score;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _timer; // starts the clock when the test opens
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _listen() async {
    final item = _session.current;
    final voices = await ref.read(installedEnglishVoicesProvider.future);
    final id = pickEnglishVoice(voices.keys.toList(), seed: _number);
    if (item == null || id == null || !mounted) return;
    setState(() => _plays++);
    await ref
        .read(passageSpeakerProvider)
        .speak([item.sentence], voice: voices[id]!)
        .drain<void>();
  }

  void _check() => setState(() => _score = scoreDictation(
        target: _session.current!.sentence,
        typed: _typed.text,
      ));

  Future<void> _next() async {
    _session.answer(_score ?? 0);
    setState(() {
      _number++;
      _plays = 0;
      _score = null;
      _typed.clear();
    });
    if (_session.isFinished && !_saved) {
      _saved = true;
      final results = await ref.read(listeningResultsProvider.future);
      await results.save(_session.level, takenAt: DateTime.now());
      ref.invalidate(latestListeningProvider);
      _timer.finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final voices = ref.watch(installedEnglishVoicesProvider);
    // Keeps the speaker (and its player) alive while this screen is open.
    ref.watch(passageSpeakerProvider);

    final Widget body;
    if (voices.isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if ((voices.value ?? const {}).isEmpty) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.englishListenNoVoice),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => GoRouter.maybeOf(context)?.push('/settings/voice/catalog'),
            child: Text(l10n.englishListenGetVoice),
          ),
        ],
      );
    } else if (_session.isFinished) {
      body = _result(l10n);
    } else {
      body = _item(l10n);
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishListeningTitle)),
      body: Padding(padding: const EdgeInsets.all(24), child: body),
    );
  }

  Widget _item(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final score = _score;
    return ListView(
      children: [
        if (_number == 1) ...[
          Text(l10n.englishListeningIntro),
          const SizedBox(height: 16),
        ],
        Text(l10n.englishListeningSentence(_number), style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _plays >= _maxPlays ? null : _listen,
          icon: const Icon(Icons.volume_up),
          label: Text(l10n.englishListen),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _typed,
          enabled: score == null,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        if (score == null)
          FilledButton(onPressed: _check, child: Text(l10n.englishListeningCheck))
        else ...[
          Text(l10n.englishListeningScore((score * 100).round()),
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(_session.current!.sentence),
          const SizedBox(height: 12),
          FilledButton(onPressed: _next, child: Text(l10n.englishListeningNext)),
        ],
      ],
    );
  }

  Widget _result(AppLocalizations l10n) {
    final level = _session.level;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          level == null
              ? l10n.englishListeningBeforeA1
              : l10n.englishListeningResult(level.name.toUpperCase()),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(l10n.englishListeningCaveat),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(l10n.englishPlacementDone),
        ),
      ],
    );
  }
}
