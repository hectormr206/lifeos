import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/offline_banner.dart';
import '../domain/meeting.dart';
import 'meetings_notifier.dart';

/// Read-only meetings list — laptop `/meetings` parity. The phone is not
/// the recorder in v1 (spec meetings-viewer): just a faithful viewer of
/// what the laptop already captured. Tap a row to open its
/// transcript/participants/summary at `/meetings/:id`.
class MeetingsScreen extends ConsumerWidget {
  const MeetingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(meetingsNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Reuniones')),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(meetingsNotifierProvider.notifier).refresh(),
              child: _buildBody(context, ref, state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, MeetingsUiState state) {
    if (state.loading) {
      return const _ScrollableCenter(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return _ScrollableCenter(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(state.error!),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => ref.read(meetingsNotifierProvider.notifier).refresh(),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (state.meetings.isEmpty) {
      return const _ScrollableCenter(child: Text('Aún no hay reuniones.'));
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: state.meetings.length,
      itemBuilder: (context, index) {
        final meeting = state.meetings[index];
        return ListTile(
          title: Text(meeting.start),
          subtitle: Text(_subtitleFor(meeting)),
          trailing: meeting.hasSummary ? const Icon(Icons.summarize_outlined) : null,
          onTap: () => context.push('/meetings/${meeting.id}'),
        );
      },
    );
  }

  String _subtitleFor(MeetingModel meeting) {
    final minutes = (meeting.durationS / 60).round();
    return '$minutes min · ${meeting.status}';
  }
}

/// Wraps non-list content (loading/error/empty) in a scrollable so
/// [RefreshIndicator]'s pull-to-refresh keeps working (same pattern as
/// `RemindersScreen`'s `_ScrollableCenter`).
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
