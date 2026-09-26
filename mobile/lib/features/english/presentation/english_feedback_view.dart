// A short review, shown the same way wherever it comes from.
//
// At most two corrections: what was written (struck through), how to say it,
// and why, in Spanish. "No important mistakes" is shown as the good news it
// is. A review the model could not produce is said plainly; nothing is shown
// half-parsed.
library;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/practice.dart';

class EnglishFeedbackView extends StatelessWidget {
  const EnglishFeedbackView({super.key, required this.feedback});

  /// Null when the model could not review.
  final PracticeFeedback? feedback;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final result = feedback;
    if (result == null) {
      return Text(l10n.englishFeedbackFailed,
          style: TextStyle(color: theme.colorScheme.error));
    }
    if (result.corrections.isEmpty) {
      return Text(l10n.englishFeedbackNone, style: theme.textTheme.titleMedium);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in result.corrections)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.wrong,
                    style: TextStyle(
                      decoration: TextDecoration.lineThrough,
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(c.right, style: theme.textTheme.titleMedium),
                  if (c.why.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(c.why, style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}
