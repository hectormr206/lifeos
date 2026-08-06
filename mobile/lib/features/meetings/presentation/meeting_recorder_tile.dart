/// The "Iniciar reunión" control.
///
/// ABSENT where the paired engine reports no recorder — a phone paired to a
/// laptop that is not in the room must not offer a button that would record
/// the wrong place. Never automatic: this is the only thing in the app that
/// starts a recording, and it takes a tap.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'meeting_recorder_providers.dart';

class MeetingRecorderTile extends ConsumerWidget {
  const MeetingRecorderTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(meetingRecorderAvailableProvider)) {
      return const SizedBox.shrink();
    }

    final state = ref.watch(meetingRecorderProvider);
    final notifier = ref.read(meetingRecorderProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            state.active ? Icons.fiber_manual_record : Icons.groups_outlined,
            color: state.active ? scheme.error : null,
          ),
          title: Text(state.active ? 'Reunión en curso' : 'Iniciar reunión'),
          subtitle: Text(
            state.active
                // The engine's own line carries the elapsed time, which is the
                // thing someone recording actually looks for.
                ? (state.detail.isEmpty ? 'Grabando…' : state.detail)
                : 'Graba micrófono, audio del sistema y pantalla en la laptop.',
          ),
          trailing: state.busy
              ? const SizedBox(
                  width: 24, height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : FilledButton.tonal(
                  onPressed: () => notifier.setActive(!state.active),
                  child: Text(state.active ? 'Detener' : 'Iniciar'),
                ),
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(state.error!, style: TextStyle(color: scheme.error)),
          ),
      ],
    );
  }
}
