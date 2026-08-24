import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/lifeos_theme.dart';
import '../../local_model/presentation/engine_failure_details.dart';
import '../../permissions/domain/app_permission.dart';
import '../../permissions/presentation/permission_request_helper.dart';
import '../domain/morning_briefing.dart';
import '../domain/summary_failure.dart';
import 'morning_briefing_notifier.dart';
import 'morning_briefing_providers.dart';

/// The ON-DEVICE "Boletín" screen: a grouped, card-per-item view of the latest
/// briefing the phone built from its feeds + Hacker News (fetch/parse/freshness,
/// NO bulk model summarization). Each item can be summarized ON DEMAND with the
/// local model; HN items can also summarize their comments. Mirrors the
/// laptop's per-item card (axi/templates/briefings.html).
class MorningBriefingScreen extends ConsumerWidget {
  const MorningBriefingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(morningBriefingNotifierProvider);
    final notifier = ref.read(morningBriefingNotifierProvider.notifier);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.briefingTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: l10n.briefingSourcesTooltip,
            onPressed: () => context.push('/settings/briefing/sources'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          _ScheduleCard(state: state, notifier: notifier),
          if (state.schedule.enabled) const _BatteryDelayCard(),
          if (state.isGenerating)
            _ProgressCard(label: state.progressLabel ?? l10n.briefingGenerating)
          else if (state.phase == BriefingPhase.error && state.error != null)
            _ErrorCard(message: state.error!),
          if (state.briefing != null) ...[
            _BriefingHeader(briefing: state.briefing!),
            // Untranslated items are no longer silent: the same engine failure
            // that stops a summary stops every translation, and this is where
            // that shows up as symptoms with no cause.
            if (state.translationFailure != null)
              _TranslationFailedNote(detail: state.translationFailure!),
            const SizedBox(height: 12),
            for (final section in state.briefing!.sections)
              _SectionBlock(
                key: ValueKey('sec::${section.section}'),
                group: section,
                digest: state.briefing!.sectionDigests[section.section],
                state: state,
                notifier: notifier,
              ),
            if (state.briefing!.skippedSources.isNotEmpty)
              _SkippedNote(sources: state.briefing!.skippedSources),
          ] else if (!state.isGenerating && state.phase != BriefingPhase.error)
            const _EmptyState(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.isGenerating ? null : notifier.generate,
        icon: state.isGenerating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.auto_awesome),
        label: Text(
          state.isGenerating
              ? l10n.briefingGenerating
              : l10n.briefingGenerateNow,
        ),
      ),
    );
  }
}

/// "Boletín automático" setting: a daily-schedule switch plus the hour picker.
class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({required this.state, required this.notifier});

  final MorningBriefingState state;
  final MorningBriefingNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final schedule = state.schedule;
    final time = TimeOfDay(hour: schedule.hour, minute: schedule.minute);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          SwitchListTile(
            title: Text(l10n.briefingScheduleTitle),
            subtitle: Text(l10n.briefingScheduleSubtitle),
            value: schedule.enabled,
            onChanged: (enabled) => notifier.setScheduleEnabled(enabled),
          ),
          if (schedule.enabled)
            ListTile(
              leading: const Icon(Icons.schedule, color: LifeOSColors.teal),
              title: Text(l10n.briefingScheduleTimeLabel),
              trailing: Text(
                time.format(context),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              onTap: () => _pickTime(context, time),
            ),
        ],
      ),
    );
  }

  Future<void> _pickTime(BuildContext context, TimeOfDay current) async {
    final picked = await showTimePicker(context: context, initialTime: current);
    if (picked == null) return;
    await notifier.setScheduleTime(picked.hour, picked.minute);
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        children: [
          const Icon(
            Icons.wb_sunny_outlined,
            size: 56,
            color: LifeOSColors.teal,
          ),
          const SizedBox(height: 16),
          Text(
            l10n.briefingEmptyTitle,
            style: textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.briefingEmptyBody,
            style: textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _BriefingHeader extends StatelessWidget {
  const _BriefingHeader({required this.briefing});

  final OnDeviceBriefing briefing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.briefingHeaderTitle, style: textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          l10n.briefingGeneratedAt(_formatTimestamp(briefing.generatedAt)),
          style: textTheme.labelMedium?.copyWith(
            color: Theme.of(context).hintColor,
          ),
        ),
      ],
    );
  }

  static String _formatTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

/// "Android puede retrasar tu boletín, y así se arregla."
///
/// Measured on a Pixel on 2026-08-24: with LifeOS in the RARE standby bucket
/// and no battery exemption, the scheduled task started ten minutes late — and
/// the OS is allowed to defer it by hours. No amount of scheduling code fixes
/// that from inside the app; only the exemption does.
///
/// So the screen says what is happening and offers the permission. It NEVER
/// asks on its own: the user grants it deliberately, with the reason in front
/// of them. Once granted — or where the permission does not exist, or once the
/// user has said no for good — the card disappears rather than nagging.
class _BatteryDelayCard extends ConsumerWidget {
  const _BatteryDelayCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(batteryUnrestrictedStateProvider);
    final resolved = state.hasValue ? state.value : null;
    if (resolved != PermissionState.denied) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Android puede retrasar tu boletín',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Para ahorrar batería, el sistema pospone las tareas de las apps '
              'que usas poco. Con este permiso tu boletín se prepara a su hora.',
              style: theme.textTheme.bodyMedium,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  await ensurePermission(
                    context,
                    ref,
                    AppPermission.batteryUnrestricted,
                  );
                  ref.invalidate(batteryUnrestrictedStateProvider);
                },
                child: const Text('Permitir'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A per-THEME block: the section name, the paragraph that says what happened
/// in it, and — folded underneath — the articles themselves.
///
/// This is the shape the whole briefing is read in. With 249 fresh articles on
/// a normal day (measured 2026-08-24), reading card by card is not a briefing;
/// the reader reads one paragraph per theme and decides what to open. So the
/// paragraph is ALWAYS visible and the cards start folded.
///
/// When a theme has no paragraph — no model, or the generation failed — the
/// headlines take its place. Nothing is invented to fill the gap, and the block
/// never pretends to have summarized news it did not read.
class _SectionBlock extends StatelessWidget {
  const _SectionBlock({
    super.key,
    required this.group,
    required this.digest,
    required this.state,
    required this.notifier,
  });

  final BriefingSectionGroup group;
  final String? digest;
  final MorningBriefingState state;
  final MorningBriefingNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = digest?.trim() ?? '';
    return Card(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 3,
                      height: 20,
                      color: LifeOSColors.teal,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        group.section,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (text.isNotEmpty)
                  Text(text, style: theme.textTheme.bodyMedium)
                else
                  // The honest fallback: no paragraph, so the headlines speak.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final article in group.articles.take(4))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            '· ${article.displayTitle}',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 4),
                Text(
                  group.sourceNames.join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: false,
              maintainState: true,
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text(
                'Ver las ${group.articles.length} noticias',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: LifeOSColors.teal,
                ),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              children: [
                for (final article in group.articles)
                  _ArticleCard(
                    key: ValueKey(article.key),
                    article: article,
                    isSummarizing: state.isSummarizingArticle(article.key),
                    isSummaryQueued: state.isQueuedArticle(article.key),
                    summaryFailure: state.articleFailures[article.key],
                    isSummarizingComments:
                        state.isSummarizingComments(article.key),
                    isCommentsQueued: state.isQueuedComments(article.key),
                    commentsFailure: state.commentFailures[article.key],
                    modelOnFallbackBackend: state.modelOnFallbackBackend,
                    onRequestSummary: () => notifier.summarizeArticle(article),
                    onRequestComments: () => notifier.summarizeComments(article),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Some items are in their original language, and here is why."
///
/// It sits under the briefing header rather than on each untranslated card: one
/// engine failure is ONE cause, and repeating it per item would bury the news
/// under the same sentence a dozen times. The items themselves are untouched —
/// they keep their original text, never blanked, never dropped.
class _TranslationFailedNote extends StatelessWidget {
  const _TranslationFailedNote({required this.detail});

  final EngineFailureDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.briefingTranslationFailed,
            style: theme.textTheme.bodySmall?.copyWith(
              color: LifeOSColors.pink,
            ),
          ),
          EngineFailureDetails(detail: detail),
        ],
      ),
    );
  }
}

/// Note listing the sources that had no fresh items today.
class _SkippedNote extends StatelessWidget {
  const _SkippedNote({required this.sources});

  final List<String> sources;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Text(
        l10n.briefingSkippedSources(sources.join(', ')),
        style: textTheme.labelMedium?.copyWith(
          color: Theme.of(context).hintColor,
        ),
      ),
    );
  }
}

/// One article card: feed-native title + brief description + a link to the full
/// article, an on-demand "Ver resumen completo", and (HN only) an on-demand
/// "Ver resumen de comentarios". Stateful so the two panels toggle locally;
/// the summary text/spinner/error come from the notifier state (props).
class _ArticleCard extends StatefulWidget {
  const _ArticleCard({
    super.key,
    required this.article,
    required this.isSummarizing,
    required this.isSummaryQueued,
    required this.summaryFailure,
    required this.isSummarizingComments,
    required this.isCommentsQueued,
    required this.commentsFailure,
    required this.modelOnFallbackBackend,
    required this.onRequestSummary,
    required this.onRequestComments,
  });

  final BriefingArticle article;
  final bool isSummarizing;

  /// The summary was requested and is WAITING for the shared model queue —
  /// deliberately distinct from [isSummarizing], so a reader who tapped two
  /// cards can see that the second one is coming rather than dead.
  final bool isSummaryQueued;

  /// The identified cause of the last failed attempt (plus its attempt count),
  /// or null when nothing failed. Deliberately NOT a pre-rendered sentence: the
  /// card decides both the wording and which action — retry, download a model,
  /// or none at all — the cause deserves.
  final SummaryAttemptFailure? summaryFailure;
  final bool isSummarizingComments;
  final bool isCommentsQueued;
  final SummaryAttemptFailure? commentsFailure;

  /// The model is loaded on a slower fallback backend, so anything it writes
  /// will take considerably longer. Shown WHILE waiting (queued/running),
  /// because that is the moment "slow" and "hung" become indistinguishable.
  final bool modelOnFallbackBackend;

  final VoidCallback onRequestSummary;
  final VoidCallback onRequestComments;

  @override
  State<_ArticleCard> createState() => _ArticleCardState();
}

class _ArticleCardState extends State<_ArticleCard> {
  bool _showSummary = false;
  bool _showComments = false;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);
    final article = widget.article;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(article.displayTitle, style: textTheme.titleMedium),
            if (article.publishedAt != null) ...[
              const SizedBox(height: 4),
              Text(
                _formatDate(article.publishedAt!),
                style: textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (article.displayDescription.isNotEmpty)
              Text(article.displayDescription, style: textTheme.bodyMedium)
            else
              // No feed brief (e.g. Hugging Face Blog, Hacker News): a subtle
              // hint instead of an empty box.
              Text(
                l10n.briefingNoSummaryHint,
                style: textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).hintColor,
                  fontStyle: FontStyle.italic,
                ),
              ),
            if (article.url.isNotEmpty) ...[
              const SizedBox(height: 12),
              InkWell(
                onTap: () => _openArticle(context, article.url, l10n),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    l10n.briefingOpenArticle,
                    style: textTheme.labelLarge?.copyWith(
                      color: LifeOSColors.teal,
                    ),
                  ),
                ),
              ),
            ],
            // On-demand full-article summary.
            if (article.url.isNotEmpty)
              _ActionRow(
                label: _showSummary
                    ? l10n.briefingHideFullSummary
                    : l10n.briefingFullSummary,
                color: LifeOSColors.teal,
                onTap: _toggleSummary,
              ),
            if (_showSummary)
              _SummaryPanel(
                loading: widget.isSummarizing,
                loadingLabel: l10n.briefingSummarizing,
                queued: widget.isSummaryQueued,
                queuedLabel: l10n.briefingSummaryQueued,
                queuedHint: l10n.briefingSummaryQueuedHint,
                failure: widget.summaryFailure,
                failureMessage: widget.summaryFailure == null
                    ? null
                    : _failureMessage(
                        l10n,
                        widget.summaryFailure!.failure,
                        comments: false,
                      ),
                slowBackend: widget.modelOnFallbackBackend,
                slowBackendLabel: l10n.briefingModelSlowBackend,
                onRetry: widget.onRequestSummary,
                onInstallModel: () => _openModelScreen(context),
                text: article.fullSummary,
              ),
            // On-demand HN comments summary.
            if (article.isHackerNews)
              _ActionRow(
                label: _showComments
                    ? l10n.briefingHideCommentsSummary
                    : l10n.briefingCommentsSummary,
                color: LifeOSColors.pink,
                onTap: _toggleComments,
              ),
            if (_showComments)
              _SummaryPanel(
                loading: widget.isSummarizingComments,
                loadingLabel: l10n.briefingSummarizingComments,
                queued: widget.isCommentsQueued,
                queuedLabel: l10n.briefingSummaryQueued,
                queuedHint: l10n.briefingSummaryQueuedHint,
                failure: widget.commentsFailure,
                failureMessage: widget.commentsFailure == null
                    ? null
                    : _failureMessage(
                        l10n,
                        widget.commentsFailure!.failure,
                        comments: true,
                      ),
                slowBackend: widget.modelOnFallbackBackend,
                slowBackendLabel: l10n.briefingModelSlowBackend,
                onRetry: widget.onRequestComments,
                onInstallModel: () => _openModelScreen(context),
                text: article.commentsSummary,
              ),
          ],
        ),
      ),
    );
  }

  /// What the reader is told for each identified cause. One sentence per cause,
  /// saying only what was actually observed — a page that could not be
  /// downloaded is never described as a paywall, and an unattributable failure
  /// says so instead of naming a plausible suspect.
  static String _failureMessage(
    AppLocalizations l10n,
    SummaryFailure failure, {
    required bool comments,
  }) => switch (failure) {
    SummaryFailure.modelMissing => l10n.briefingSummaryErrorNoModel,
    SummaryFailure.modelUnavailable => l10n.briefingSummaryErrorModelLoad,
    SummaryFailure.pageUnavailable =>
      comments
          ? l10n.briefingCommentsErrorFetch
          : l10n.briefingSummaryErrorFetch,
    SummaryFailure.pageUnreadable => l10n.briefingSummaryErrorUnreadable,
    SummaryFailure.commentsMissing => l10n.briefingCommentsErrorNone,
    SummaryFailure.emptyGeneration => l10n.briefingSummaryErrorEmpty,
    SummaryFailure.unknown => l10n.briefingSummaryErrorUnknown,
  };

  /// The answer to "there is no model": the download screen, one tap away —
  /// the same deep-link shape the update banner uses for `/settings/updates`.
  static void _openModelScreen(BuildContext context) =>
      context.push('/settings/local-model');

  /// A failure that nothing can fix is not re-run behind the user's back when
  /// he reopens the panel: the explanation is already there, and a second
  /// identical fetch is work he never asked for.
  static bool _isPermanent(SummaryAttemptFailure? failure) =>
      failure != null && failure.failure.recovery == SummaryRecovery.none;

  void _toggleSummary() {
    setState(() => _showSummary = !_showSummary);
    if (_showSummary &&
        (widget.article.fullSummary ?? '').isEmpty &&
        !widget.isSummarizing &&
        !_isPermanent(widget.summaryFailure)) {
      widget.onRequestSummary();
    }
  }

  void _toggleComments() {
    setState(() => _showComments = !_showComments);
    if (_showComments &&
        (widget.article.commentsSummary ?? '').isEmpty &&
        !widget.isSummarizingComments &&
        !_isPermanent(widget.commentsFailure)) {
      widget.onRequestComments();
    }
  }

  /// Opens the article in the EXTERNAL browser — the action the link's own
  /// label promises.
  ///
  /// It used to copy the URL to the clipboard instead, leaving the user to
  /// paste it somewhere by hand. A control that says "Ver noticia completa"
  /// and quietly does something else is worse than one that fails: the user
  /// cannot tell it went wrong.
  ///
  /// When nothing on the device can handle the link, it SAYS so and offers
  /// copying as an explicit action. The message is shown BEFORE any clipboard
  /// work — telling the user must never sit behind an await that can hang, or
  /// a stuck clipboard swallows the explanation too and the tap looks dead.
  Future<void> _openArticle(
    BuildContext context,
    String url,
    AppLocalizations l10n,
  ) async {
    final uri = Uri.tryParse(url);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false; // No handler, or the platform refused it.
      }
    }
    if (opened || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.briefingOpenFailed),
        action: SnackBarAction(
          label: l10n.briefingCopyLinkAction,
          onPressed: () => _copyLink(messenger, url, l10n),
        ),
      ),
    );
  }

  /// Copies the link on the user's explicit request, and confirms it.
  Future<void> _copyLink(
    ScaffoldMessengerState messenger,
    String url,
    AppLocalizations l10n,
  ) async {
    try {
      await Clipboard.setData(ClipboardData(text: url));
      messenger.showSnackBar(SnackBar(content: Text(l10n.briefingLinkCopied)));
    } catch (_) {
      // Even the clipboard refused: say that rather than claim a copy.
      messenger.showSnackBar(SnackBar(content: Text(l10n.briefingCopyFailed)));
    }
  }

  static String _formatDate(DateTime dtUtc) {
    final local = dtUtc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)} ${two(local.hour)}:${two(local.minute)}';
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color),
        ),
      ),
    );
  }
}

/// The box under a "ver resumen" action. It has FOUR distinct looks, because
/// the reader has to be able to tell them apart at a glance:
///   * WAITING — the request is accepted and queued behind another summary:
///     a clock icon and "En cola…", no spinner (nothing is being computed yet);
///   * RUNNING — a spinner and "Resumiendo…";
///   * DONE — the summary text;
///   * FAILED — WHAT failed, and the one thing worth doing about it.
///
/// The failed look is the one this screen got wrong in build 799: every cause
/// printed "No se pudo generar el resumen. Inténtalo de nuevo.", and the only
/// way to try again was to collapse and reopen the panel. Now the message names
/// the cause and carries exactly one of three shapes — retry it, download a
/// model, or nothing (this item will not work) — plus the attempt count, so a
/// retry that fails again in milliseconds still visibly changes the card.
class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({
    required this.loading,
    required this.loadingLabel,
    required this.queued,
    required this.queuedLabel,
    required this.queuedHint,
    required this.failure,
    required this.failureMessage,
    required this.slowBackend,
    required this.slowBackendLabel,
    required this.onRetry,
    required this.onInstallModel,
    required this.text,
  });

  final bool loading;
  final String loadingLabel;
  final bool queued;
  final String queuedLabel;
  final String queuedHint;
  final SummaryAttemptFailure? failure;
  final String? failureMessage;

  /// The model fell back to a slower backend. Announced in the WAITING and
  /// RUNNING looks only: that is when the user is deciding whether this is
  /// still working, and it is not news worth repeating over a finished summary.
  final bool slowBackend;
  final String slowBackendLabel;

  final VoidCallback onRetry;
  final VoidCallback onInstallModel;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget child;
    if (queued) {
      // No spinner: nothing is running yet. A clock says "your turn is coming"
      // where a spinner would claim work that has not started.
      child = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.schedule, size: 16, color: theme.hintColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(queuedLabel, style: theme.textTheme.bodySmall),
                Text(
                  queuedHint,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
                if (slowBackend) _slowBackendLine(theme),
              ],
            ),
          ),
        ],
      );
    } else if (loading) {
      child = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(loadingLabel, style: theme.textTheme.bodySmall),
                if (slowBackend) _slowBackendLine(theme),
              ],
            ),
          ),
        ],
      );
    } else if (failure != null) {
      child = _FailurePanel(
        failure: failure!,
        message: failureMessage ?? '',
        onRetry: onRetry,
        onInstallModel: onInstallModel,
      );
    } else if ((text ?? '').isNotEmpty) {
      child = Text(text!, style: theme.textTheme.bodyMedium);
    } else {
      child = const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }

  /// The "this is slow, not stuck" line. Deliberately part of the WAIT itself
  /// rather than a settings-screen note or a one-time dialog: the question
  /// ("why is nothing happening?") is asked here, at this moment, and a notice
  /// the user has to go looking for — or one shown once and forgotten — does
  /// not answer it.
  Widget _slowBackendLine(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      slowBackendLabel,
      style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
    ),
  );
}

/// The FAILED look: the cause in words, the repeat-failure count once there is
/// one, and the single action that cause deserves.
class _FailurePanel extends StatelessWidget {
  const _FailurePanel({
    required this.failure,
    required this.message,
    required this.onRetry,
    required this.onInstallModel,
  });

  final SummaryAttemptFailure failure;
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onInstallModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: theme.textTheme.bodySmall?.copyWith(color: LifeOSColors.pink),
        ),
        // From the second failure on: the retry IS running, and failing fast.
        // Without this line the identical message repaints and the tap reads as
        // if it had been swallowed.
        if (failure.attempt > 1)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.briefingSummaryRetryFailedAgain(failure.attempt),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ),
        switch (failure.failure.recovery) {
          SummaryRecovery.retry => Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(l10n.briefingSummaryRetryAction),
            ),
          ),
          // No model: retrying fails identically forever, so the card offers
          // the thing that actually fixes it instead.
          SummaryRecovery.installModel => Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onInstallModel,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(l10n.briefingSummaryInstallModelAction),
            ),
          ),
          // Permanent for this item: say so rather than invite a loop of taps
          // that will each fail the same way.
          SummaryRecovery.none => Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.briefingSummaryNotRetryable,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ),
        },
        // COLLAPSED, and last: the sentence above stays the headline. This is
        // the underlying exception, kept because it is the only evidence of
        // WHY the model could not be used — and there is no way to recover it
        // from the device afterwards. Absent for causes that never touched the
        // model, where there is no exception to show.
        if (failure.detail != null)
          EngineFailureDetails(detail: failure.detail!),
      ],
    );
  }
}
