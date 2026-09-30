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

import '../../../l10n/app_localizations.dart';
import '../../../theme/lifeos_tokens.dart';
import '../data/activity_log.dart';
import '../data/passage_speaker.dart';
import '../domain/daily_plan.dart';
import '../domain/listening_placement.dart';
import 'english_providers.dart';
import '../../tts/domain/tts_voice.dart';
import '../../voice_settings/presentation/voice_catalog_providers.dart';

/// Plays per sentence: a second chance, not a loop.
const int _maxPlays = 2;

class EnglishListeningScreen extends ConsumerStatefulWidget {
  const EnglishListeningScreen({super.key});

  @override
  ConsumerState<EnglishListeningScreen> createState() =>
      _EnglishListeningScreenState();
}

class _EnglishListeningScreenState
    extends ConsumerState<EnglishListeningScreen> {
  final _session = ListeningPlacement();
  final _typed = TextEditingController();
  late final PassageSpeaker _speaker;
  late final ActivityTimer _timer = ActivityTimer(
    ActivityKind.placement,
    ref.read(activityLogProvider.future),
  );
  int _number = 1;
  int _plays = 0;
  double? _score;
  bool _saved = false;
  bool _playing = false;
  bool _heard = false;
  bool _advancing = false;
  bool _saving = false;
  bool _saveFailed = false;
  bool _playFailed = false;
  int _playEpoch = 0;

  @override
  void initState() {
    super.initState();
    _timer; // starts the clock when the test opens
    _speaker = ref.read(passageSpeakerProvider);
  }

  @override
  void dispose() {
    _playEpoch++;
    // Stop the active player as the route leaves. Do not await from dispose.
    _speaker.stop().catchError((Object _) {});
    _typed.dispose();
    super.dispose();
  }

  Future<void> _listen() async {
    if (_playing ||
        _plays >= _maxPlays ||
        _score != null ||
        _session.isFinished) {
      return;
    }
    final item = _session.current;
    if (item == null) return;
    final epoch = ++_playEpoch;
    setState(() {
      _playing = true;
      _playFailed = false;
    });
    try {
      final voices = await ref.read(installedEnglishVoicesProvider.future);
      if (!mounted || epoch != _playEpoch) return;
      final id = pickEnglishVoice(voices.keys.toList(), seed: _number);
      if (id == null) throw StateError('English voice unavailable');
      await _speaker.speak([item.sentence], voice: voices[id]!).drain<void>();
      if (!mounted || epoch != _playEpoch) return;
      setState(() {
        _plays++;
        _heard = true;
      });
    } catch (error) {
      if (mounted && epoch == _playEpoch) {
        setState(() => _playFailed = true);
      }
    } finally {
      if (mounted && epoch == _playEpoch) {
        setState(() => _playing = false);
      }
    }
  }

  void _check({bool understoodNothing = false}) {
    if (!_heard ||
        _playing ||
        _score != null ||
        _session.isFinished ||
        (!understoodNothing && _typed.text.trim().isEmpty)) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(
      () => _score = understoodNothing
          ? 0
          : scoreDictation(
              target: _session.current!.sentence,
              typed: _typed.text.trim(),
            ),
    );
  }

  Future<void> _next() async {
    if (_score == null || _playing || _advancing || _session.isFinished) return;
    _advancing = true;
    _session.answer(_score!);
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _number++;
      _plays = 0;
      _heard = false;
      _playFailed = false;
      _score = null;
      _typed.clear();
    });
    if (_session.isFinished) {
      await _save();
    } else {
      _advancing = false;
    }
  }

  Future<void> _save() async {
    if (_saved || _saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      final results = await ref.read(listeningResultsProvider.future);
      await results.save(_session.level, takenAt: DateTime.now());
      if (!mounted) return;
      ref.invalidate(latestListeningProvider);
      _timer.finish();
      setState(() => _saved = true);
    } catch (error) {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _advancing = false;
        });
      }
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
      // Downloaded here, never through the voice catalog: there, downloading
      // a voice also makes it Axi's voice.
      final status = ref.watch(
        voiceCatalogControllerProvider,
      )[kPracticeVoiceId];
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.englishListenNoVoice),
          const SizedBox(height: Space.lg),
          if (status is TtsVoiceDownloading)
            Text(l10n.englishVoiceDownloading((status.progress * 100).round()))
          else ...[
            if (status is TtsVoiceFailed) Text(l10n.englishVoiceFailed),
            FilledButton(
              onPressed: () => downloadEnglishVoice(ref),
              child: Text(l10n.englishListenGetVoice),
            ),
          ],
        ],
      );
    } else if (_session.isFinished) {
      body = _saved ? _result(l10n) : _pendingSave(l10n);
    } else {
      body = _item(l10n);
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishListeningTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(kPageGutter, Space.sm, kPageGutter, Space.xxl),
            child: body,
          ),
        ),
      ),
    );
  }

  Widget _item(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final score = _score;
    return ListView(
      children: [
        if (_number == 1) ...[
          Text(l10n.englishListeningIntro),
          const SizedBox(height: Space.lg),
        ],
        Text(
          l10n.englishListeningSentence(_number),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: Space.md),
        OutlinedButton.icon(
          onPressed: _playing || _plays >= _maxPlays || score != null
              ? null
              : _listen,
          icon: const Icon(Icons.volume_up),
          label: Text(l10n.englishListen),
        ),
        if (_playing) const Center(child: CircularProgressIndicator()),
        if (_playFailed) Text(l10n.englishListenFailed),
        const SizedBox(height: Space.md),
        TextField(
          controller: _typed,
          onChanged: (_) => setState(() {}),
          enabled: score == null,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        const SizedBox(height: Space.md),
        if (score == null) ...[
          FilledButton(
            onPressed: _heard && !_playing && _typed.text.trim().isNotEmpty
                ? _check
                : null,
            child: Text(l10n.englishListeningCheck),
          ),
          if (_heard && !_playing)
            TextButton(
              onPressed: () => _check(understoodNothing: true),
              child: Text(l10n.englishListeningDidNotUnderstand),
            ),
        ] else ...[
          Text(
            l10n.englishListeningScore((score * 100).round()),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: Space.xs),
          Text(_session.current!.sentence),
          const SizedBox(height: Space.md),
          FilledButton(
            onPressed: _advancing ? null : _next,
            child: Text(l10n.englishListeningNext),
          ),
        ],
      ],
    );
  }

  Widget _pendingSave(AppLocalizations l10n) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_saving) const Center(child: CircularProgressIndicator()),
      if (_saveFailed) ...[
        Text(l10n.englishListeningSaveFailed),
        FilledButton(onPressed: _save, child: Text(l10n.englishListeningRetry)),
      ],
    ],
  );

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
        const SizedBox(height: Space.md),
        Text(l10n.englishListeningCaveat),
        const SizedBox(height: Space.xxl),
        FilledButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(l10n.englishPlacementDone),
        ),
      ],
    );
  }
}
