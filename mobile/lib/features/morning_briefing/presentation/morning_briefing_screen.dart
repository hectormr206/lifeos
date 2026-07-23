import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/lifeos_theme.dart';
import '../domain/morning_briefing.dart';
import 'morning_briefing_notifier.dart';

/// The ON-DEVICE "Boletín" screen: shows the latest briefing the phone
/// generated with its local model, a "Generar boletín ahora" button that runs
/// the pipeline (with progress), and access to the source-URL editor.
///
/// Deliberately separate from the pairing-gated Boletines viewer
/// (`/briefings`, features/briefings) which mirrors the laptop dashboard: this
/// one is produced entirely on device and needs no engine connection.
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
            for (final item in state.briefing!.items) _BriefingItemCard(item: item),
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

/// "Boletín automático" setting: a daily-schedule switch plus the hour picker
/// (default 8:00). Persisted through the notifier so the OS reminder and the
/// in-app trigger re-arm immediately on every change.
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
          const Icon(Icons.wb_sunny_outlined, size: 56, color: LifeOSColors.teal),
          const SizedBox(height: 16),
          Text(l10n.briefingEmptyTitle, style: textTheme.titleMedium, textAlign: TextAlign.center),
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
          style: textTheme.labelMedium?.copyWith(color: Theme.of(context).hintColor),
        ),
        if (briefing.intro.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(briefing.intro, style: textTheme.bodyLarge),
        ],
      ],
    );
  }

  static String _formatTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _BriefingItemCard extends StatelessWidget {
  const _BriefingItemCard({required this.item});

  final BriefingItem item;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.sourceTitle, style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(item.summary, style: textTheme.bodyMedium),
            if (item.url.isNotEmpty) ...[
              const SizedBox(height: 12),
              InkWell(
                onTap: () => _copyLink(context, item.url),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.link, size: 16, color: LifeOSColors.teal),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          item.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelMedium?.copyWith(color: LifeOSColors.teal),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _copyLink(BuildContext context, String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).briefingLinkCopied)),
    );
  }
}
