// TODO(i18n): hardcoded neutral Spanish pending the i18n sweep of the
// reminders screens (the viewer half of this screen is not localized yet
// either — both localize together).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/reminder_notifications.dart';
import '../domain/local_reminder.dart';
import 'local_reminders_notifier.dart';
import 'local_reminders_providers.dart';

/// The LOCAL half of the reminders screen (roadmap slice C2): reminders
/// created/stored/scheduled ON THIS DEVICE — no pairing, no engine. List of
/// pending/fired local reminders, NL quick-create (Dart parser, device
/// clock), a date/time picker fallback when the text carries no parseable
/// time, and complete/delete per row.
class LocalRemindersTab extends ConsumerStatefulWidget {
  const LocalRemindersTab({super.key});

  @override
  ConsumerState<LocalRemindersTab> createState() => _LocalRemindersTabState();
}

class _LocalRemindersTabState extends ConsumerState<LocalRemindersTab> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    // While the app is alive, a reminder-notification tap lands here (the
    // payload registry keeps one handler per payload; re-registering on each
    // open just refreshes it). Cold-start routing is a follow-up — see
    // local_reminders_providers.dart.
    final scheduler = ref.read(reminderSchedulerProvider);
    if (scheduler is NotificationReminderScheduler) {
      scheduler.registerTapHandler(() {
        if (!mounted) return;
        ref.read(localRemindersNotifierProvider.notifier).refresh();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final notifier = ref.read(localRemindersNotifierProvider.notifier);
    final parsed = notifier.parse(text);
    if (parsed != null && parsed.dueAt != null) {
      // NL parse succeeded ("llamar al doctor mañana a las 3").
      await notifier.create(
        text: parsed.text.isEmpty ? text : parsed.text,
        dueAt: parsed.dueAt!,
        recurrence: parsed.recurrence,
      );
      _controller.clear();
      return;
    }
    // No parseable time → require an explicit one via pickers.
    final message = (parsed != null && parsed.text.isNotEmpty) ? parsed.text : text;
    final dueAt = await _pickDateTime();
    if (dueAt == null) return;
    await notifier.create(text: message, dueAt: dueAt);
    _controller.clear();
  }

  /// Explicit date + time pickers (the "unparseable → ask for a time" path).
  /// [initial] pre-seeds the pickers when editing an existing reminder.
  Future<DateTime?> _pickDateTime({DateTime? initial}) async {
    final now = DateTime.now();
    final seed = initial ?? now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: seed.isBefore(now) ? now : seed,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365 * 2)),
      helpText: '¿Qué día te lo recuerdo?',
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(seed),
      helpText: '¿A qué hora?',
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  /// Edit an existing reminder: change its text and, optionally, its date/time.
  Future<void> _edit(LocalReminder reminder) async {
    final controller = TextEditingController(text: reminder.text);
    var dueAt = reminder.dueAt;
    final notifier = ref.read(localRemindersNotifierProvider.notifier);
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          String two(int n) => n.toString().padLeft(2, '0');
          final whenText =
              '${two(dueAt.day)}/${two(dueAt.month)}/${dueAt.year} ${two(dueAt.hour)}:${two(dueAt.minute)}';
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Editar recordatorio',
                    style: Theme.of(sheetContext).textTheme.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: '¿Qué te recuerdo?',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: const Text('Fecha y hora'),
                  subtitle: Text(whenText),
                  trailing: const Icon(Icons.edit),
                  onTap: () async {
                    final picked = await _pickDateTime(initial: dueAt);
                    if (picked != null) setSheetState(() => dueAt = picked);
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      child: const Text('Cancelar'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(true),
                      child: const Text('Guardar cambios'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
    if (saved == true) {
      final text = controller.text.trim();
      await notifier.edit(
        reminder,
        text: text.isEmpty ? reminder.text : text,
        dueAt: dueAt,
        recurrence: reminder.recurrence,
      );
    }
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localRemindersNotifierProvider);

    return Column(
      children: [
        // Errors (store unavailable, failed action) surface INLINE — a
        // SnackBar here would float over the sibling tab's bottom bar.
        if (state.error != null && state.reminders.isNotEmpty)
          MaterialBanner(
            content: Text(state.error!),
            actions: [
              TextButton(
                onPressed: () => ref
                    .read(localRemindersNotifierProvider.notifier)
                    .refresh(),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () =>
                ref.read(localRemindersNotifierProvider.notifier).refresh(),
            child: _buildList(state),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Ej. "comprar pan mañana a las 8"',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _create(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.alarm_add),
                  tooltip: 'Crear recordatorio local',
                  onPressed: _create,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildList(LocalRemindersUiState state) {
    if (state.loading) {
      return const _ScrollableCenter(child: CircularProgressIndicator());
    }
    if (state.error != null && state.reminders.isEmpty) {
      return _ScrollableCenter(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(state.error!, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () =>
                  ref.read(localRemindersNotifierProvider.notifier).refresh(),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (state.reminders.isEmpty) {
      return const _ScrollableCenter(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No tienes recordatorios en este dispositivo.\n'
            'Escribe uno abajo, por ejemplo: "llamar al doctor mañana a las 3".',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: state.reminders.length,
      itemBuilder: (context, index) {
        final reminder = state.reminders[index];
        return _LocalReminderTile(
          reminder: reminder,
          onDone: () => ref
              .read(localRemindersNotifierProvider.notifier)
              .complete(reminder),
          onDelete: () =>
              ref.read(localRemindersNotifierProvider.notifier).remove(reminder),
          onEdit: () => _edit(reminder),
          onToggleEnabled: (enabled) => ref
              .read(localRemindersNotifierProvider.notifier)
              .setEnabled(reminder, enabled),
        );
      },
    );
  }
}

class _LocalReminderTile extends StatelessWidget {
  const _LocalReminderTile({
    required this.reminder,
    required this.onDone,
    required this.onDelete,
    required this.onEdit,
    required this.onToggleEnabled,
  });

  final LocalReminder reminder;
  final VoidCallback onDone;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggleEnabled;

  @override
  Widget build(BuildContext context) {
    final fired = reminder.status == LocalReminderStatus.fired;
    final disabled = reminder.isDisabled;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        disabled
            ? Icons.notifications_off_outlined
            : (reminder.recurrence == ReminderRecurrence.daily
                ? Icons.repeat
                : Icons.alarm),
        color: disabled
            ? scheme.outline
            : (fired ? scheme.tertiary : null),
      ),
      title: Text(
        reminder.text,
        style: disabled ? TextStyle(color: scheme.outline) : null,
      ),
      subtitle: Text(_subtitle()),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Deactivate / reactivate without deleting.
          Switch(
            value: !disabled,
            onChanged: onToggleEnabled,
          ),
          PopupMenuButton<String>(
            tooltip: 'Acciones',
            onSelected: (action) {
              switch (action) {
                case 'edit':
                  onEdit();
                case 'done':
                  onDone();
                case 'delete':
                  onDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Editar')),
              PopupMenuItem(value: 'done', child: Text('Marcar como hecho')),
              PopupMenuItem(value: 'delete', child: Text('Eliminar')),
            ],
          ),
        ],
      ),
    );
  }

  String _subtitle() {
    final local = reminder.dueAt;
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(local.hour)}:${two(local.minute)}';
    final base = reminder.recurrence == ReminderRecurrence.daily
        ? 'Todos los días a las $time'
        : '${two(local.day)}/${two(local.month)}/${local.year} $time';
    if (reminder.isDisabled) return '$base · desactivado';
    if (reminder.status == LocalReminderStatus.fired) return '$base · ya sonó';
    return base;
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
