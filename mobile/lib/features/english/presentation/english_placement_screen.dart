// The English vocabulary placement: one word at a time, "I know it" or not.
//
// Three promises, each with a test:
//   1. The invented words are announced BEFORE the first one appears. A trap
//      nobody was told about feels like a trick, and someone who has already
//      quit Duolingo twice does not need another reason to feel stupid.
//   2. A guessed result is never presented as a level. It says so plainly and
//      offers a retake instead.
//   3. Every attempt is kept, reliable or not, and a save that fails is said
//      out loud rather than lost in silence.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/vocab_placement_scoring.dart';
import '../domain/vocab_placement_session.dart';
import 'english_providers.dart';
import 'english_words_label.dart';

class EnglishPlacementScreen extends ConsumerStatefulWidget {
  const EnglishPlacementScreen({super.key});

  @override
  ConsumerState<EnglishPlacementScreen> createState() =>
      _EnglishPlacementScreenState();
}

class _EnglishPlacementScreenState
    extends ConsumerState<EnglishPlacementScreen> {
  VocabPlacementSession? _session;
  VocabPlacementResult? _result;
  int _answered = 0;
  bool _saveFailed = false;

  void _start(VocabBank bank) => setState(() {
        _session = VocabPlacementSession(bank);
        _result = null;
        _answered = 0;
        _saveFailed = false;
      });

  void _answer({required bool knows}) {
    final session = _session!;
    session.answer(knows: knows);
    setState(() => _answered++);
    if (!session.isFinished) return;

    final result = scoreVocabPlacement(session.tallies);
    setState(() => _result = result);
    _save(result);
  }

  Future<void> _save(VocabPlacementResult result) async {
    try {
      final history = await ref.read(placementHistoryProvider.future);
      await history.save(result, takenAt: DateTime.now());
      ref.invalidate(latestPlacementProvider);
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishPlacementTitle)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ref.watch(vocabBankProvider).when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => Center(child: Text(l10n.englishPlacementLoadError)),
                data: (bank) {
                  final result = _result;
                  if (result != null) return _resultView(l10n, bank, result);
                  final session = _session;
                  if (session != null) return _wordView(l10n, session);
                  return _introView(l10n, bank);
                },
              ),
        ),
      ),
    );
  }

  Widget _introView(AppLocalizations l10n, VocabBank bank) {
    final last = ref.watch(latestPlacementProvider).value;
    return ListView(
      children: [
        Text(l10n.englishPlacementIntro),
        const SizedBox(height: 12),
        Text(
          l10n.englishPlacementWarning,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Text(l10n.englishPlacementLength),
        if (last != null) ...[
          const SizedBox(height: 24),
          Text(l10n.englishPlacementLast(
            last.result.cefr.name.toUpperCase(),
            last.result.estimatedWords,
          )),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => _start(bank),
          child: Text(l10n.englishPlacementStart),
        ),
      ],
    );
  }

  Widget _wordView(AppLocalizations l10n, VocabPlacementSession session) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(l10n.englishPlacementProgress(_answered + 1)),
        const SizedBox(height: 32),
        Text(
          session.current!.text,
          key: const Key('english-placement-word'),
          style: Theme.of(context).textTheme.displaySmall,
        ),
        const SizedBox(height: 48),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('english-placement-no'),
                onPressed: () => _answer(knows: false),
                child: Text(l10n.englishPlacementDontKnow),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton(
                key: const Key('english-placement-yes'),
                onPressed: () => _answer(knows: true),
                child: Text(l10n.englishPlacementKnow),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _resultView(
    AppLocalizations l10n,
    VocabBank bank,
    VocabPlacementResult result,
  ) {
    final headline = Theme.of(context).textTheme.headlineSmall;
    return ListView(
      children: [
        if (result.reliable) ...[
          Text(englishWordsLabel(l10n, result.estimatedWords), style: headline),
          const SizedBox(height: 8),
          Text(l10n.englishPlacementLevel(result.cefr.name.toUpperCase())),
          const SizedBox(height: 16),
          Text(l10n.englishPlacementScope),
        ] else
          Text(l10n.englishPlacementUnreliable),
        if (_saveFailed) ...[
          const SizedBox(height: 16),
          Text(
            l10n.englishPlacementSaveFailed,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () => _start(bank),
          child: Text(l10n.englishPlacementRetake),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(l10n.englishPlacementDone),
        ),
      ],
    );
  }
}
