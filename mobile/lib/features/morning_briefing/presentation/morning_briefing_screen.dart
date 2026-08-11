import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/lifeos_theme.dart';
import '../domain/morning_briefing.dart';
import 'morning_briefing_notifier.dart';

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
          if (state.isGenerating)
            _ProgressCard(label: state.progressLabel ?? l10n.briefingGenerating)
          else if (state.phase == BriefingPhase.error && state.error != null)
            _ErrorCard(message: state.error!),
          if (state.briefing != null) ...[
            _BriefingHeader(briefing: state.briefing!),
            const SizedBox(height: 12),
            for (final group in state.briefing!.groups)
              _SourceSection(
                key: ValueKey('src::${group.sourceName}'),
                group: group,
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
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.auto_awesome),
        label: Text(state.isGenerating ? l10n.briefingGenerating : l10n.briefingGenerateNow),
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
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
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
            Expanded(child: Text(message, style: TextStyle(color: scheme.onErrorContainer))),
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
          const Icon(Icons.wb_sunny_outlined, size: 56, color: LifeOSColors.teal),
          const SizedBox(height: 16),
          Text(l10n.briefingEmptyTitle, style: textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(l10n.briefingEmptyBody, style: textTheme.bodyMedium, textAlign: TextAlign.center),
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
          style: textTheme.labelMedium?.copyWith(color: Theme.of(context).hintColor),
        ),
      ],
    );
  }

  static String _formatTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

/// A per-source COLLAPSIBLE section: a header showing `Source (count)`,
/// COLLAPSED by default, that reveals the source's item cards when tapped. The
/// titles/briefs are ALREADY translated (eagerly, at generation time) so the
/// cards render in the app language immediately — no tap-to-translate.
class _SourceSection extends StatelessWidget {
  const _SourceSection({
    super.key,
    required this.group,
    required this.state,
    required this.notifier,
  });

  final BriefingGroup group;
  final MorningBriefingState state;
  final MorningBriefingNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Drop the ExpansionTile's default divider lines for a cleaner card.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          // Collapsed by default; expansion state is kept per screen session.
          initiallyExpanded: false,
          maintainState: true,
          leading: Container(width: 3, height: 20, color: LifeOSColors.teal),
          title: Text(
            '${group.sourceName} (${group.articles.length})',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          children: [
            for (final article in group.articles)
              _ArticleCard(
                key: ValueKey(article.key),
                article: article,
                isSummarizing: state.isSummarizingArticle(article.key),
                isSummaryQueued: state.isQueuedArticle(article.key),
                summaryError: state.articleErrors[article.key],
                isSummarizingComments: state.isSummarizingComments(article.key),
                isCommentsQueued: state.isQueuedComments(article.key),
                commentsError: state.commentErrors[article.key],
                onRequestSummary: () => notifier.summarizeArticle(article),
                onRequestComments: () => notifier.summarizeComments(article),
              ),
          ],
        ),
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
        style: textTheme.labelMedium?.copyWith(color: Theme.of(context).hintColor),
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
    required this.summaryError,
    required this.isSummarizingComments,
    required this.isCommentsQueued,
    required this.commentsError,
    required this.onRequestSummary,
    required this.onRequestComments,
  });

  final BriefingArticle article;
  final bool isSummarizing;

  /// The summary was requested and is WAITING for the shared model queue —
  /// deliberately distinct from [isSummarizing], so a reader who tapped two
  /// cards can see that the second one is coming rather than dead.
  final bool isSummaryQueued;
  final String? summaryError;
  final bool isSummarizingComments;
  final bool isCommentsQueued;
  final String? commentsError;
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
                style: textTheme.labelSmall?.copyWith(color: Theme.of(context).hintColor),
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
                    style: textTheme.labelLarge?.copyWith(color: LifeOSColors.teal),
                  ),
                ),
              ),
            ],
            // On-demand full-article summary.
            if (article.url.isNotEmpty)
              _ActionRow(
                label: _showSummary ? l10n.briefingHideFullSummary : l10n.briefingFullSummary,
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
                error: widget.summaryError,
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
                error: widget.commentsError,
                text: article.commentsSummary,
              ),
          ],
        ),
      ),
    );
  }

  void _toggleSummary() {
    setState(() => _showSummary = !_showSummary);
    if (_showSummary && (widget.article.fullSummary ?? '').isEmpty && !widget.isSummarizing) {
      widget.onRequestSummary();
    }
  }

  void _toggleComments() {
    setState(() => _showComments = !_showComments);
    if (_showComments &&
        (widget.article.commentsSummary ?? '').isEmpty &&
        !widget.isSummarizingComments) {
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
  Future<void> _openArticle(BuildContext context, String url, AppLocalizations l10n) async {
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
  const _ActionRow({required this.label, required this.color, required this.onTap});

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
///   * FAILED — the error message.
class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({
    required this.loading,
    required this.loadingLabel,
    required this.queued,
    required this.queuedLabel,
    required this.queuedHint,
    required this.error,
    required this.text,
  });

  final bool loading;
  final String loadingLabel;
  final bool queued;
  final String queuedLabel;
  final String queuedHint;
  final String? error;
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
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
          ),
        ],
      );
    } else if (loading) {
      child = Row(
        children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Text(loadingLabel, style: theme.textTheme.bodySmall),
        ],
      );
    } else if (error != null) {
      child = Text(error!, style: theme.textTheme.bodySmall?.copyWith(color: LifeOSColors.pink));
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
}
