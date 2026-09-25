// "Recordarme cada día": one daily reminder, at a time the learner picks.
//
// A habit needs a cue at the same moment each day (Lally et al. 2010), and a
// reminder is the simplest cue there is. It is an ordinary LifeOS reminder
// (data/english_reminder.dart); once set, this shows its time instead of
// the button, so it is never created twice. A picker left without a time
// creates nothing, and a reminder that could not be created is said.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import 'english_providers.dart';

final _reminderTimeProvider = FutureProvider.autoDispose<TimeOfDay?>(
  (ref) async => (await ref.watch(englishReminderProvider.future)).existingTime(),
);

class EnglishReminderTile extends ConsumerStatefulWidget {
  const EnglishReminderTile({super.key});

  @override
  ConsumerState<EnglishReminderTile> createState() => _EnglishReminderTileState();
}

class _EnglishReminderTileState extends ConsumerState<EnglishReminderTile> {
  bool _failed = false;

  Future<void> _set() async {
    final time = await ref.read(reminderTimePickerProvider)(context);
    if (time == null) return;
    try {
      await (await ref.read(englishReminderProvider.future)).create(time);
      ref.invalidate(_reminderTimeProvider);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final existing = ref.watch(_reminderTimeProvider);
    if (existing.isLoading) return const SizedBox.shrink();
    final time = existing.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (time != null)
          Text(l10n.englishReminderSet(
              MaterialLocalizations.of(context).formatTimeOfDay(time,
                  alwaysUse24HourFormat: true)))
        else
          OutlinedButton.icon(
            onPressed: _set,
            icon: const Icon(Icons.alarm),
            label: Text(l10n.englishReminderButton),
          ),
        if (_failed)
          Text(l10n.englishReminderFailed,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}
