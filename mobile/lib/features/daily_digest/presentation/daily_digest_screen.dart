// TODO(i18n): hardcoded neutral Spanish, consistent with the domains /
// reminders / briefing screens (they localize together in a later ARB pass).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/daily_digest.dart';
import '../domain/daily_digest_schedule.dart';
import 'daily_digest_notifier.dart';

/// The on-device DAILY DIGEST screen: shows today's generated summary (model
/// wrap-up + the exact aggregated facts) and lets the user manage the built-in
/// schedule — edit the time + wrap-up instructions, or deactivate it. The
/// digest is a BUILT-IN: it can be edited and turned off, but never deleted.
class DailyDigestScreen extends ConsumerStatefulWidget {
  const DailyDigestScreen({super.key});

  @override
  ConsumerState<DailyDigestScreen> createState() => _DailyDigestScreenState();
}

class _DailyDigestScreenState extends ConsumerState<DailyDigestScreen> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dailyDigestNotifierProvider);
    final notifier = ref.read(dailyDigestNotifierProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Resumen del día')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ScheduleCard(schedule: state.schedule, notifier: notifier),
          const SizedBox(height: 12),
          _InstructionsCard(instructions: state.instructions, notifier: notifier),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: state.isGenerating ? null : notifier.generate,
            icon: state.isGenerating
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(state.isGenerating ? 'Preparando…' : 'Generar ahora'),
          ),
          if (state.error != null) ...[
            const SizedBox(height: 12),
            Text(state.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          if (state.digest != null)
            _DigestView(digest: state.digest!)
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Aún no hay un resumen. Se prepara solo a la hora programada, '
                'o puedes generarlo ahora.',
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({required this.schedule, required this.notifier});

  final DailyDigestSchedule schedule;
  final DailyDigestNotifier notifier;

  @override
  Widget build(BuildContext context) {
    String two(int n) => n.toString().padLeft(2, '0');
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Resumen automático'),
            subtitle: const Text('Se prepara solo cada día (integrado, no se puede eliminar).'),
            value: schedule.enabled,
            onChanged: notifier.setScheduleEnabled,
          ),
          ListTile(
            enabled: schedule.enabled,
            leading: const Icon(Icons.schedule),
            title: const Text('Hora'),
            subtitle: Text('${two(schedule.hour)}:${two(schedule.minute)}'),
            trailing: const Icon(Icons.edit),
            onTap: schedule.enabled
                ? () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(hour: schedule.hour, minute: schedule.minute),
                      helpText: '¿A qué hora preparo tu resumen?',
                    );
                    if (picked != null) {
                      await notifier.setScheduleTime(picked.hour, picked.minute);
                    }
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

class _InstructionsCard extends StatefulWidget {
  const _InstructionsCard({required this.instructions, required this.notifier});

  final String instructions;
  final DailyDigestNotifier notifier;

  @override
  State<_InstructionsCard> createState() => _InstructionsCardState();
}

class _InstructionsCardState extends State<_InstructionsCard> {
  late final TextEditingController _controller = TextEditingController(text: widget.instructions);

  @override
  void didUpdateWidget(covariant _InstructionsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the field in sync when the notifier resets/loads a new value and the
    // field is not being actively edited.
    if (widget.instructions != oldWidget.instructions &&
        widget.instructions != _controller.text) {
      _controller.text = widget.instructions;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Instrucciones del resumen', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text(
              'Con esto Axi le da forma a la redacción. Los datos siempre son '
              'exactos; esto solo cambia el tono/estilo.',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              maxLines: 4,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => widget.notifier.resetInstructions(),
                  child: const Text('Restablecer'),
                ),
                FilledButton(
                  onPressed: () => widget.notifier.setInstructions(_controller.text),
                  child: const Text('Guardar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DigestView extends StatelessWidget {
  const _DigestView({required this.digest});

  final DailyDigest digest;

  @override
  Widget build(BuildContext context) {
    String two(int n) => n.toString().padLeft(2, '0');
    final at = digest.generatedAt.toLocal();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Generado el ${two(at.day)}/${two(at.month)}/${at.year} a las ${two(at.hour)}:${two(at.minute)}',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 8),
        if (digest.wrapUp.isNotEmpty) ...[
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(digest.wrapUp),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text('Detalle de hoy', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(digest.deterministicText),
      ],
    );
  }
}
