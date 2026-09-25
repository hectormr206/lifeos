// "Con personas reales": get ready before, learn after.
//
// From B1 on, people are what the app cannot replace, and the screen opens by
// saying so. Before a real conversation: describe it, get phrases at your
// level and the questions you will probably hear, then rehearse with the model
// playing the other person (the ordinary role-play screen, opening with one of
// those questions). After it: write each thing you wanted to say and could
// not, one per line, and get how to say it; each can be kept for review, with
// what you meant as its meaning. A model that cannot help is said, never faked.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../data/activity_log.dart';
import '../data/word_gloss.dart';
import '../domain/daily_plan.dart';
import '../domain/real_talk.dart';
import '../domain/vocab_placement_scoring.dart';
import 'english_providers.dart';
import 'english_roleplay_screen.dart';

class EnglishRealTalkScreen extends ConsumerStatefulWidget {
  const EnglishRealTalkScreen({super.key});

  @override
  ConsumerState<EnglishRealTalkScreen> createState() =>
      _EnglishRealTalkScreenState();
}

class _EnglishRealTalkScreenState extends ConsumerState<EnglishRealTalkScreen> {
  final _situation = TextEditingController();
  final _wanted = TextEditingController();
  late final ActivityTimer _timer =
      ActivityTimer(ActivityKind.write, ref.read(activityLogProvider.future));

  bool _busy = false;
  bool _failed = false;
  Prep? _prep;
  List<(String wanted, String say)> _said = const [];
  final Set<String> _kept = {};

  @override
  void initState() {
    super.initState();
    _timer; // starts the clock when the screen opens
  }

  @override
  void dispose() {
    _situation.dispose();
    _wanted.dispose();
    super.dispose();
  }

  String get _situationText => _situation.text.trim();

  Future<void> _prepare() async {
    if (_situationText.isEmpty) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final level =
        (await ref.read(latestPlacementProvider.future))?.result.cefr ??
            CefrLevel.a2;
    final prep = await ref
        .read(realTalkServiceProvider)
        .prepare(situation: _situationText, level: level);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _prep = prep;
      _failed = prep == null;
    });
  }

  Future<void> _rephraseAll() async {
    final lines = wantedLines(_wanted.text);
    if (lines.isEmpty) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final service = ref.read(realTalkServiceProvider);
    final said = <(String, String)>[];
    for (final wanted in lines) {
      final say =
          await service.rephrase(wanted: wanted, situation: _situationText);
      if (say != null) said.add((wanted, say));
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _said = said;
      _failed = said.isEmpty;
    });
    if (said.isNotEmpty) _timer.finish();
  }

  Future<void> _keep(String wanted, String say) async {
    final saver = await ref.read(wordSaverProvider.future);
    await saver.save(
      lemma: say,
      gloss: wanted,
      context: SavedContext(sentence: say, source: 'real-talk'),
    );
    if (mounted) setState(() => _kept.add(say));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final prep = _prep;
    final header = theme.textTheme.titleMedium;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishRealTitle)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(l10n.englishRealIntro),
          const SizedBox(height: 16),
          TextField(
            key: const Key('real-talk-situation'),
            controller: _situation,
            decoration: InputDecoration(
              labelText: l10n.englishRealSituation,
              border: const OutlineInputBorder(),
            ),
            minLines: 2,
            maxLines: 4,
          ),
          const SizedBox(height: 24),
          Text(l10n.englishRealBefore, style: header),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _prepare,
            child: Text(l10n.englishRealPrepare),
          ),
          if (prep != null) ...[
            const SizedBox(height: 12),
            Text(l10n.englishRealPhrases, style: theme.textTheme.titleSmall),
            for (final p in prep.phrases) Text(p),
            if (prep.questions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(l10n.englishRealQuestions, style: theme.textTheme.titleSmall),
              for (final q in prep.questions) Text(q),
            ],
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => EnglishRoleplayScreen(
                  scenario: rehearsalScenario(situation: _situationText, prep: prep),
                ),
              )),
              child: Text(l10n.englishRealRehearse),
            ),
          ],
          const SizedBox(height: 24),
          Text(l10n.englishRealAfter, style: header),
          const SizedBox(height: 8),
          TextField(
            key: const Key('real-talk-wanted'),
            controller: _wanted,
            decoration: InputDecoration(
              labelText: l10n.englishRealWanted,
              border: const OutlineInputBorder(),
            ),
            minLines: 3,
            maxLines: 6,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _rephraseAll,
            child: Text(l10n.englishRealHowToSay),
          ),
          for (final (wanted, say) in _said)
            Card(
              child: ListTile(
                title: Text(say),
                subtitle: Text(wanted),
                trailing: _kept.contains(say)
                    ? Text(l10n.englishReaderSaved)
                    : TextButton(
                        onPressed: () => _keep(wanted, say),
                        child: Text(l10n.englishReaderSave),
                      ),
              ),
            ),
          if (_busy) const LinearProgressIndicator(),
          if (_failed)
            Text(l10n.englishRealFailed,
                style: TextStyle(color: theme.colorScheme.error)),
        ],
      ),
    );
  }
}
