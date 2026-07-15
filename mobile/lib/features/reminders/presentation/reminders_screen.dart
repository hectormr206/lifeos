import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/offline_banner.dart';
import '../domain/reminder.dart';
import 'reminders_notifier.dart';

/// Pending reminders — the "visible soul" slice. Mirrors `DomainListScreen`'s
/// list + NL quick-capture layout: a scrollable list of pending reminders,
/// each with a "mark done" action (DELETE, the engine's only completion
/// action — see `RemindersRepository.cancel`), plus a bottom bar reusing
/// the chat endpoint for natural-language create.
class RemindersScreen extends ConsumerStatefulWidget {
  const RemindersScreen({super.key});

  @override
  ConsumerState<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends ConsumerState<RemindersScreen> {
  final _createController = TextEditingController();
  String? _lastShownCaptureError;

  @override
  void dispose() {
    _createController.dispose();
    super.dispose();
  }

  void _create() {
    final text = _createController.text;
    if (text.trim().isEmpty) return;
    ref.read(remindersNotifierProvider.notifier).capture(text);
    _createController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(remindersNotifierProvider);

    ref.listen(remindersNotifierProvider, (previous, next) {
      if (next.captureError != null && next.captureError != _lastShownCaptureError) {
        _lastShownCaptureError = next.captureError;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.captureError!)));
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Recordatorios')),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(remindersNotifierProvider.notifier).refresh(),
              child: _buildBody(state),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _createController,
                      decoration: const InputDecoration(
                        hintText: 'Recuérdame… ej. "llamar al doctor mañana a las 3"',
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _create(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: state.capturing
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.add),
                    tooltip: 'Crear recordatorio',
                    onPressed: state.capturing ? null : _create,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(RemindersUiState state) {
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
              onPressed: () => ref.read(remindersNotifierProvider.notifier).refresh(),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (state.reminders.isEmpty) {
      return const _ScrollableCenter(child: Text('No tienes recordatorios pendientes.'));
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: state.reminders.length,
      itemBuilder: (context, index) => _ReminderTile(
        reminder: state.reminders[index],
        onDone: () => ref.read(remindersNotifierProvider.notifier).markDone(state.reminders[index].id),
      ),
    );
  }
}

class _ScrollableCenter extends StatelessWidget {
  const _ScrollableCenter({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: constraints.maxHeight,
            child: Center(child: child),
          ),
        ],
      ),
    );
  }
}

class _ReminderTile extends StatelessWidget {
  const _ReminderTile({required this.reminder, required this.onDone});

  final ReminderModel reminder;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(reminder.message),
      subtitle: Text(_formatTimestamp(reminder.whenTs)),
      trailing: IconButton(
        icon: const Icon(Icons.check_circle_outline),
        tooltip: 'Marcar como hecho',
        onPressed: onDone,
      ),
    );
  }

  String _formatTimestamp(DateTime ts) {
    final local = ts.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
  }
}
