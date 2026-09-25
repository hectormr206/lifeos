// "Sonidos para practicar": the one or two sound tips under a recording.
//
// Each tip names the sound, says how to make it (the mouth, not phonetics
// jargon) and what was heard, in IPA between brackets, for the learner who
// wants the detail. The section says it is a guide: the phone model makes
// mistakes too. Without the model it offers the download, with its size.
library;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/pron_feedback.dart';
import 'english_providers.dart';

String soundTipTitle(AppLocalizations l10n, SoundPattern pattern) =>
    switch (pattern) {
      SoundPattern.shortI => l10n.englishTipShortITitle,
      SoundPattern.catVowel => l10n.englishTipCatVowelTitle,
      SoundPattern.vAsB => l10n.englishTipVAsBTitle,
      SoundPattern.thVoiceless => l10n.englishTipThVoicelessTitle,
      SoundPattern.eBeforeS => l10n.englishTipEBeforeSTitle,
      SoundPattern.zAsS => l10n.englishTipZAsSTitle,
      SoundPattern.thVoiced => l10n.englishTipThVoicedTitle,
      SoundPattern.cupVowel => l10n.englishTipCupVowelTitle,
      SoundPattern.bookVowel => l10n.englishTipBookVowelTitle,
      SoundPattern.shSound => l10n.englishTipShSoundTitle,
      SoundPattern.jSound => l10n.englishTipJSoundTitle,
      SoundPattern.hAsJota => l10n.englishTipHAsJotaTitle,
      SoundPattern.finalSound => l10n.englishTipFinalSoundTitle,
      SoundPattern.spanishR => l10n.englishTipSpanishRTitle,
    };

String soundTipHow(AppLocalizations l10n, SoundPattern pattern) =>
    switch (pattern) {
      SoundPattern.shortI => l10n.englishTipShortIHow,
      SoundPattern.catVowel => l10n.englishTipCatVowelHow,
      SoundPattern.vAsB => l10n.englishTipVAsBHow,
      SoundPattern.thVoiceless => l10n.englishTipThVoicelessHow,
      SoundPattern.eBeforeS => l10n.englishTipEBeforeSHow,
      SoundPattern.zAsS => l10n.englishTipZAsSHow,
      SoundPattern.thVoiced => l10n.englishTipThVoicedHow,
      SoundPattern.cupVowel => l10n.englishTipCupVowelHow,
      SoundPattern.bookVowel => l10n.englishTipBookVowelHow,
      SoundPattern.shSound => l10n.englishTipShSoundHow,
      SoundPattern.jSound => l10n.englishTipJSoundHow,
      SoundPattern.hAsJota => l10n.englishTipHAsJotaHow,
      SoundPattern.finalSound => l10n.englishTipFinalSoundHow,
      SoundPattern.spanishR => l10n.englishTipSpanishRHow,
    };

class SoundTipsSection extends StatelessWidget {
  const SoundTipsSection({
    super.key,
    required this.status,
    required this.tips,
    this.working = false,
    required this.onDownload,
  });

  final PronModelStatus status;

  /// Null when there are none to show (not run, or it failed).
  final List<SoundTip>? tips;

  /// The phone model is listening to the recording.
  final bool working;

  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tips = this.tips;

    final Widget? body = switch (status.state) {
      PronModelState.checking => null,
      PronModelState.absent => TextButton(
          onPressed: onDownload, child: Text(l10n.englishSoundsDownload)),
      PronModelState.failed => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.englishSoundsFailed,
                style: TextStyle(color: theme.colorScheme.error)),
            TextButton(
                onPressed: onDownload, child: Text(l10n.englishSoundsDownload)),
          ],
        ),
      PronModelState.downloading => Text(l10n.englishSoundsDownloading(
          (status.progress * 100).round())),
      PronModelState.ready => working
          ? Text(l10n.englishSoundsWorking)
          : tips == null
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.englishSoundsTitle,
                        style: theme.textTheme.titleMedium),
                    if (tips.isEmpty) Text(l10n.englishSoundsNone),
                    for (final tip in tips)
                      Card(
                        child: ListTile(
                          title: Text(soundTipTitle(l10n, tip.pattern)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(soundTipHow(l10n, tip.pattern)),
                              const SizedBox(height: 4),
                              Text(
                                tip.heard.isEmpty
                                    ? l10n.englishSoundsMissing(
                                        tip.words.join(', '), tip.expected)
                                    : l10n.englishSoundsHeard(
                                        tip.words.join(', '),
                                        tip.heard,
                                        tip.expected),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    Text(l10n.englishSoundsCaveat,
                        style: theme.textTheme.bodySmall),
                  ],
                ),
    };
    return body ?? const SizedBox.shrink();
  }
}
