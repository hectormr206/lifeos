import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/offline_banner.dart';
import 'meeting_detail_notifier.dart';

/// One meeting's detail: transcript (segment-by-segment, speaker-attributed),
/// participants, and summary — laptop `/meetings/{id}` parity, minus
/// screen-capture images (out of scope this slice, an auth'd binary
/// endpoint — future add).
class MeetingDetailScreen extends ConsumerWidget {
  const MeetingDetailScreen({required this.meetingId, super.key});

  final int meetingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = meetingDetailNotifierProvider(meetingId);
    final state = ref.watch(provider);

    return Scaffold(
      appBar: AppBar(title: Text(state.detail?.start ?? 'Reunión')),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(provider.notifier).refresh(),
              child: _buildBody(context, state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, MeetingDetailUiState state) {
    if (state.loading) {
      return const _ScrollableCenter(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return _ScrollableCenter(child: Text(state.error!));
    }
    final detail = state.detail;
    if (detail == null) {
      return const _ScrollableCenter(child: Text('Reunión no encontrada.'));
    }
    final minutes = (detail.durationS / 60).round();
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          detail.end != null ? '${detail.start} – ${detail.end}' : detail.start,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text('$minutes min · ${detail.status}'),
        const SizedBox(height: 16),
        if (detail.summary != null && detail.summary!.isNotEmpty)
          _Section(
            title: 'Resumen',
            empty: 'Sin resumen.',
            children: [Text(detail.summary!)],
          ),
        _Section(
          title: 'Participantes',
          empty: 'Sin participantes detectados.',
          children: [
            for (final speaker in detail.speakers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(speaker.name),
                trailing: Text('${speaker.segmentCount}'),
              ),
          ],
        ),
        _Section(
          title: 'Transcripción',
          empty: 'Sin transcripción.',
          children: [
            for (final segment in detail.segments)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(segment.speakerLabel ?? 'Desconocido', style: Theme.of(context).textTheme.labelMedium),
                    Text(segment.text),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.empty, required this.children});

  final String title;
  final String empty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          if (children.isEmpty) Text(empty) else ...children,
        ],
      ),
    );
  }
}

/// Wraps non-list content (loading/error/not-found) in a scrollable so
/// [RefreshIndicator]'s pull-to-refresh keeps working (same pattern as
/// `GraphNodeScreen`'s `_ScrollableCenter`).
class _ScrollableCenter extends StatelessWidget {
  const _ScrollableCenter({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: constraints.maxHeight, child: Center(child: child)),
        ],
      ),
    );
  }
}
