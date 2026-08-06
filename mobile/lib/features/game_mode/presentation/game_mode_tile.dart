/// The "Modo juego" switch.
///
/// ABSENT where the engine reports no GPU — see [GameModeAvailability]. And
/// never automatic: this switch is the only thing in the app that turns game
/// mode on, because the user activates it himself.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'game_mode_providers.dart';

class GameModeTile extends ConsumerWidget {
  const GameModeTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final availability = ref.watch(gameModeAvailabilityProvider);
    if (!availability.available) return const SizedBox.shrink();

    final state = ref.watch(gameModeProvider);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: state.busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sports_esports_outlined),
          title: const Text('Modo juego'),
          subtitle: Text(
            state.busy
                // The relocation restarts services and loads a model into RAM.
                // Saying "un momento" beats a switch that appears to hang.
                ? 'Reubicando los modelos… puede tardar unos segundos.'
                : 'Libera la VRAM de ${availability.gpuLabel ?? "la GPU"} '
                    'moviendo Axi a CPU y RAM.',
          ),
          value: state.active,
          // Disabled only while a change is in flight — not as a way of
          // expressing "unsupported", which is what hiding is for.
          onChanged: state.busy
              ? null
              : (value) => ref.read(gameModeProvider.notifier).setActive(value),
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              state.error!,
              style: TextStyle(color: scheme.error),
            ),
          ),
      ],
    );
  }
}
