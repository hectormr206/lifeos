import 'package:flutter/material.dart';
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
            for (final group in state.briefing!.groups) ...[
              _SourceHeader(name: group.sourceName),
              for (final article in group.articles)
                _ArticleCard(
                  key: ValueKey(article.key),
                  article: article,
                  isSummarizing: state.isSummarizingArticle(article.key),
                  summaryError: state.articleErrors[article.key],
                  isSummarizingComments: state.isSummarizingComments(article.key),
                  commentsError: state.commentErrors[article.key],
                  onRequestSummary: () => notifier.summarizeArticle(article),
                  onRequestComments: () => notifier.summarizeComments(article),
                ),
            ],
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

/// A per-source section header (source name) preceding its item cards.
class _SourceHeader extends StatelessWidget {
  const _SourceHeader({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Row(
        children: [
          Container(width: 3, height: 18, color: LifeOSColors.teal),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
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
    required this.summaryError,
    required this.isSummarizingComments,
    required this.commentsError,
    required this.onRequestSummary,
    required this.onRequestComments,
  });

  final BriefingArticle article;
  final bool isSummarizing;
  final String? summaryError;
  final bool isSummarizingComments;
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
            Text(article.title, style: textTheme.titleMedium),
            if (article.publishedAt != null) ...[
              const SizedBox(height: 4),
              Text(
                _formatDate(article.publishedAt!),
                style: textTheme.labelSmall?.copyWith(color: Theme.of(context).hintColor),
              ),
            ],
            if (article.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(article.description, style: textTheme.bodyMedium),
            ],
            if (article.url.isNotEmpty) ...[
              const SizedBox(height: 12),
              InkWell(
                onTap: () => _copyLink(context, article.url, l10n),
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

  Future<void> _copyLink(BuildContext context, String url, AppLocalizations l10n) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.briefingLinkCopied)));
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

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({
    required this.loading,
    required this.loadingLabel,
    required this.error,
    required this.text,
  });

  final bool loading;
  final String loadingLabel;
  final String? error;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget child;
    if (loading) {
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
