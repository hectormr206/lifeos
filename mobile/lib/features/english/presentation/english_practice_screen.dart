// Practice: what there is to do for the learner's goal.
//
// Conversations (role-plays) and writing tasks, both from the goal. Without a
// goal it asks for one first, since
// the goal is what decides whether the practice is a client proposal or a
// note to a child's school.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../core/widgets/widgets.dart';
import '../../../theme/lifeos_tokens.dart';
import '../domain/practice.dart';
import 'english_goal_picker.dart';
import 'english_feedback_view.dart';
import '../data/activity_log.dart';
import '../domain/daily_plan.dart';
import 'english_providers.dart';
import 'english_real_talk_screen.dart';
import 'english_roleplay_screen.dart';

class EnglishPracticeScreen extends ConsumerWidget {
  const EnglishPracticeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final goal = ref.watch(englishGoalProvider);

    Widget body;
    if (goal.isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (goal.value == null) {
      body = PageBody(
        children: const [EnglishGoalPicker()],
      );
    } else {
      body = PageBody(
        children: [
          // With people: the part the app does not replace, first in view.
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const EnglishRealTalkScreen(),
            )),
            child: Text(l10n.englishRealEntry),
          ),
          SectionHeader(l10n.englishPracticeTalk),
          GroupedList(children: [
            for (final scenario in roleplaysFor(goal.value!))
              GroupedRow(
                title: scenario.title,
                subtitle: scenario.task,
                subtitleMaxLines: null,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => EnglishRoleplayScreen(scenario: scenario),
                )),
              ),
          ]),
          SectionHeader(l10n.englishPracticeWrite),
          GroupedList(children: [
            for (final task in writingTasksFor(goal.value!))
              GroupedRow(
                title: task.title,
                subtitle: task.prompt,
                subtitleMaxLines: null,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => EnglishWritingScreen(task: task),
                )),
              ),
          ]),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishPracticeTitle)),
      body: body,
    );
  }
}

/// Write in English, then get at most two corrections.
class EnglishWritingScreen extends ConsumerStatefulWidget {
  const EnglishWritingScreen({super.key, required this.task});

  final WritingTask task;

  @override
  ConsumerState<EnglishWritingScreen> createState() =>
      _EnglishWritingScreenState();
}

class _EnglishWritingScreenState extends ConsumerState<EnglishWritingScreen> {
  final _text = TextEditingController();
  bool _reviewing = false;
  bool _reviewed = false;
  PracticeFeedback? _feedback;

  late final ActivityTimer _timer =
      ActivityTimer(ActivityKind.write, ref.read(activityLogProvider.future));

  @override
  void initState() {
    super.initState();
    _timer; // starts the clock when the task opens
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _review() async {
    // The keyboard would cover the review that is about to appear.
    FocusScope.of(context).unfocus();
    setState(() => _reviewing = true);
    final feedback =
        await ref.read(practiceServiceProvider).review(_text.text.trim());
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
    return Scaffold(
      appBar: AppBar(title: Text(widget.task.title)),
      body: PageBody(
        children: [
          Text(widget.task.prompt, style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.sm),
          Text(l10n.englishWriteHint, style: theme.textTheme.bodySmall),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _text,
            minLines: 5,
            maxLines: 12,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: Space.lg),
          FilledButton(
            onPressed: _reviewing || _text.text.trim().isEmpty ? null : _review,
            child: Text(_reviewing ? l10n.englishReviewing : l10n.englishWriteReview),
          ),
          if (_reviewed) ...[
            const SizedBox(height: Space.xxl),
            EnglishFeedbackView(feedback: _feedback),
          ],
        ],
      ),
    );
  }
}
