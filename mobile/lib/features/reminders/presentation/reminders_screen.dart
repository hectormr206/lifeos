// TODO(i18n): hardcoded neutral Spanish pending the i18n sweep (this screen
// predates the ARB slice and was never localized).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/offline_banner.dart';
import '../../../core/widgets/pending_sync_banner.dart';
import '../domain/reminder.dart';
import 'local_reminders_tab.dart';
import 'reminders_notifier.dart';

/// Reminders — two coexisting surfaces (roadmap slice C2):
///   * "En este teléfono": LOCAL reminders created, stored (graph store) and
///     scheduled ON-DEVICE ([LocalRemindersTab]). Works unpaired/offline —
///     this is why the `/reminders` route is no longer pairing-gated.
///   * "Desde tu laptop": the original pairing-gated VIEWER of the engine's
///     reminders ([EngineRemindersTab], the "visible soul" slice) — list +
///     NL quick-capture via the chat endpoint, "mark done" via DELETE.
///     Unpaired it simply shows its own connection error.
class RemindersScreen extends StatelessWidget {
  const RemindersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Recordatorios'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'En este teléfono', icon: Icon(Icons.smartphone)),
              Tab(text: 'Desde tu laptop', icon: Icon(Icons.laptop_mac)),
            ],
          ),
        ),
        body: const TabBarView(
          children: [LocalRemindersTab(), EngineRemindersTab()],
        ),
      ),
    );
  }
}

/// The engine-reminders VIEWER (unchanged behavior, now hosted as a tab).
/// Mirrors `DomainListScreen`'s list + NL quick-capture layout: a scrollable
/// list of pending reminders, each with a "mark done" action (DELETE, the
/// engine's only completion action — see `RemindersRepository.cancel`), plus
/// a bottom bar reusing the chat endpoint for natural-language create.
class EngineRemindersTab extends ConsumerStatefulWidget {
  const EngineRemindersTab({super.key});

  @override
  ConsumerState<EngineRemindersTab> createState() => _EngineRemindersTabState();
}

class _EngineRemindersTabState extends ConsumerState<EngineRemindersTab> {
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
      if (next.captureError != null &&
          next.captureError != _lastShownCaptureError) {
        _lastShownCaptureError = next.captureError;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(next.captureError!)));
      }
    });

    return Column(
      children: [
        const OfflineBanner(),
        const PendingSyncBanner(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () =>
                ref.read(remindersNotifierProvider.notifier).refresh(),
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
                      hintText:
                          'Recuérdame… ej. "llamar al doctor mañana a las 3"',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _create(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: state.capturing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                  tooltip: 'Crear recordatorio',
                  onPressed: state.capturing ? null : _create,
                ),
              ],
            ),
          ),
        ),
      ],
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
              onPressed: () =>
                  ref.read(remindersNotifierProvider.notifier).refresh(),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (state.reminders.isEmpty) {
      return const _ScrollableCenter(
        child: Text('No tienes recordatorios pendientes.'),
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: state.reminders.length,
      itemBuilder: (context, index) => _ReminderTile(
        reminder: state.reminders[index],
        onDone: () => ref
            .read(remindersNotifierProvider.notifier)
            .markDone(state.reminders[index].id),
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
