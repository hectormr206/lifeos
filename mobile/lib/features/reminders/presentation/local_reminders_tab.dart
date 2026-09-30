// TODO(i18n): hardcoded neutral Spanish pending the i18n sweep of the
// reminders screens (the viewer half of this screen is not localized yet
// either — both localize together).
import 'package:flutter/material.dart';
import '../../../core/widgets/widgets.dart';
import '../../../theme/lifeos_tokens.dart';
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
    // This notifier survives route exit. English (and other features) can
    // create reminders through the shared service while its list is cached.
    // Wait for the first load before refreshing to avoid a stale load winning.
    _refreshOnEntry(ref.read(localRemindersNotifierProvider.notifier));
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

  Future<void> _refreshOnEntry(LocalRemindersNotifier notifier) async {
    await notifier.ready;
    if (!mounted) return;
    await notifier.refresh();
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
              left: kPageGutter,
              right: kPageGutter,
              top: Space.lg,
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom + Space.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Editar recordatorio',
                    style: Theme.of(sheetContext).textTheme.titleMedium),
                const SizedBox(height: Space.md),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: '¿Qué te recuerdo?',
                  ),
                ),
                const SizedBox(height: Space.md),
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
                const SizedBox(height: Space.sm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      child: const Text('Cancelar'),
                    ),
                    const SizedBox(width: Space.sm),
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

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
        child: Column(
          children: [
            // Keep store and action errors inline, above the refresh area.
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
                onRefresh: () => ref
                    .read(localRemindersNotifierProvider.notifier)
                    .refresh(),
                child: _buildList(state),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    kPageGutter, Space.sm, kPageGutter, Space.md),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: const InputDecoration(
                          hintText: 'Ej. "comprar pan mañana a las 8"',
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _create(),
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    // An empty box offers nothing to create; preserve the
                    // disabled affordance until meaningful text is entered.
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _controller,
                      builder: (context, value, _) => IconButton(
                        icon: const Icon(Icons.alarm_add),
                        tooltip: 'Crear recordatorio local',
                        onPressed: value.text.trim().isEmpty ? null : _create,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(LocalRemindersUiState state) {
    if (state.loading) {
      return const ScrollableCenter(child: CircularProgressIndicator());
    }
    if (state.error != null && state.reminders.isEmpty) {
      return _ScrollableEmptyState(
        child: EmptyState(
          icon: Icons.error_outline,
          title: state.error!,
          action: OutlinedButton(
            onPressed: () => ref.read(localRemindersNotifierProvider.notifier).refresh(),
            child: const Text('Reintentar'),
          ),
        ),
      );
    }
    if (state.reminders.isEmpty) {
      return const _ScrollableEmptyState(
        child: EmptyState(
          icon: Icons.notifications_outlined,
          title: 'No tienes recordatorios en este dispositivo.',
          message: 'Escribe uno abajo, por ejemplo: "llamar al doctor mañana a las 3".',
        ),
      );
    }
    final notifier = ref.read(localRemindersNotifierProvider.notifier);
    return GroupedListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(kPageGutter, Space.sm, kPageGutter, Space.xxl),
      itemCount: state.reminders.length,
      itemBuilder: (context, index) {
        final reminder = state.reminders[index];
        return _LocalReminderTile(
          reminder: reminder,
          onDone: () => notifier.complete(reminder),
          onDelete: () => notifier.remove(reminder),
          onEdit: () => _edit(reminder),
          onToggleEnabled: (enabled) => notifier.setEnabled(reminder, enabled),
        );
      },
    );
  }
}

/// Center when there is room, scroll when the keyboard or a short viewport
/// leaves less height than the guidance needs. Retain pull-to-refresh physics.
class _ScrollableEmptyState extends StatelessWidget {
  const _ScrollableEmptyState({required this.child});

  final EmptyState child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: const EdgeInsets.all(kPageGutter),
            child: child,
          ),
        ),
      ],
    ),
  );
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
    final text = Theme.of(context).textTheme;
    String two(int n) => n.toString().padLeft(2, '0');
    return ListTile(
      minVerticalPadding: Space.md,
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg),
      horizontalTitleGap: Space.md,
      leading: Text(
        '${two(reminder.dueAt.hour)}:${two(reminder.dueAt.minute)}',
        style: text.titleLarge?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
          color: disabled ? scheme.onSurfaceVariant : (fired ? scheme.tertiary : scheme.onSurface),
        ),
      ),
      title: Text(
        reminder.text,
        style: text.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: disabled ? scheme.onSurfaceVariant : scheme.onSurface,
        ),
      ),
      subtitle: Text(_subtitle(),
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
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
