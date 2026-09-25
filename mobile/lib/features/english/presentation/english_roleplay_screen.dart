// A role-play: talk with a character, then get the two things that matter.
//
// The character opens, and the learner's goal for the scene stays in view.
// Answers can be typed or spoken: speech goes through Whisper into the box so
// it can be checked before sending. The character answers in simple English
// at the learner's level (A2 when there is no placement yet: too simple beats
// lost) and never corrects mid-talk. "Terminar y revisar" reviews everything
// the learner said at once, at most two corrections. A character that does
// not answer is said, never a silent spinner.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/chat_providers.dart';
import '../../stt/presentation/stt_providers.dart';
import '../data/passage_speaker.dart';
import '../domain/practice.dart';
import '../domain/vocab_placement_scoring.dart';
import 'english_feedback_view.dart';
import '../data/activity_log.dart';
import '../domain/daily_plan.dart';
import 'english_providers.dart';

/// The level used before any placement: simpler rather than lost.
const CefrLevel _defaultLevel = CefrLevel.a2;

class EnglishRoleplayScreen extends ConsumerStatefulWidget {
  const EnglishRoleplayScreen({super.key, required this.scenario});

  final RoleplayScenario scenario;

  @override
  ConsumerState<EnglishRoleplayScreen> createState() =>
      _EnglishRoleplayScreenState();
}

class _EnglishRoleplayScreenState extends ConsumerState<EnglishRoleplayScreen> {
  late final List<PracticeTurn> _turns = [
    PracticeTurn(fromLearner: false, text: widget.scenario.opening),
  ];
  final _input = TextEditingController();
  bool _waiting = false;
  bool _noReply = false;
  bool _recording = false;
  bool _reviewing = false;
  bool _reviewed = false;
  PracticeFeedback? _feedback;

  late final ActivityTimer _timer =
      ActivityTimer(ActivityKind.talk, ref.read(activityLogProvider.future));

  @override
  void initState() {
    super.initState();
    _timer; // starts the clock when the conversation opens
  }

  @override
  void dispose() {
    // Leaving without the review still counts a conversation that happened.
    if (_turns.any((t) => t.fromLearner)) _timer.finish();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _turns.add(PracticeTurn(fromLearner: true, text: text));
      _input.clear();
      _waiting = true;
      _noReply = false;
    });
    final level =
        (await ref.read(latestPlacementProvider.future))?.result.cefr ??
            _defaultLevel;
    final reply = await ref
        .read(practiceServiceProvider)
        .reply(scenario: widget.scenario, level: level, turns: _turns);
    if (!mounted) return;
    setState(() {
      _waiting = false;
      if (reply == null) {
        _noReply = true;
      } else {
        _turns.add(PracticeTurn(fromLearner: false, text: reply));
      }
    });
  }

  Future<void> _toggleSpeaking() async {
    final recorder = ref.read(audioRecorderGatewayProvider);
    if (!_recording) {
      if (!await recorder.hasPermission()) return;
      await recorder.start();
      setState(() => _recording = true);
      return;
    }
    setState(() => _recording = false);
    final path = await recorder.stop();
    if (path == null) return;
    try {
      final heard = await ref
          .read(speechToTextProvider)
          .transcribe(path, languageCode: 'en');
      if (mounted) setState(() => _input.text = heard);
    } catch (_) {
      // Nothing heard: the box stays as it was, ready to type instead.
    }
  }

  Future<void> _listen(String text) async {
    final voices = await ref.read(installedEnglishVoicesProvider.future);
    final id = pickEnglishVoice(voices.keys.toList(), seed: widget.scenario.id.length);
    if (id == null) return;
    await ref.read(passageSpeakerProvider).speak([text], voice: voices[id]!).drain<void>();
  }

  Future<void> _finish() async {
    final said = [
      for (final t in _turns)
        if (t.fromLearner) t.text,
    ].join('\n');
    if (said.isEmpty) return;
    setState(() => _reviewing = true);
    final feedback = await ref.read(practiceServiceProvider).review(said);
    if (!mounted) return;
    setState(() {
      _reviewing = false;
      _reviewed = true;
      _feedback = feedback;
    });
    _timer.finish();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // Keeps the speaker (and its player) alive while this screen is open.
    ref.watch(passageSpeakerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.scenario.title),
        actions: [
          TextButton(
            onPressed: _reviewing ? null : _finish,
            child: Text(l10n.englishTalkFinish),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.englishTalkGoal(widget.scenario.task),
                    style: theme.textTheme.titleSmall),
                Text(l10n.englishTalkHint, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final turn in _turns)
                  Align(
                    alignment: turn.fromLearner
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Card(
                      color: turn.fromLearner
                          ? theme.colorScheme.primaryContainer
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(child: Text(turn.text)),
                            if (!turn.fromLearner)
                              IconButton(
                                tooltip: l10n.englishListen,
                                icon: const Icon(Icons.volume_up, size: 20),
                                onPressed: () => _listen(turn.text),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_waiting) const LinearProgressIndicator(),
                if (_noReply)
                  Text(l10n.englishTalkNoReply,
                      style: TextStyle(color: theme.colorScheme.error)),
                if (_reviewing) Text(l10n.englishReviewing),
                if (_reviewed) ...[
                  const SizedBox(height: 16),
                  EnglishFeedbackView(feedback: _feedback),
                ],
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: _recording
                        ? l10n.englishTalkDoneSpeaking
                        : l10n.englishTalkSpeak,
                    icon: Icon(_recording ? Icons.stop : Icons.mic),
                    onPressed: _toggleSpeaking,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.englishTalkSend,
                    icon: const Icon(Icons.send),
                    onPressed: _waiting ? null : _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
