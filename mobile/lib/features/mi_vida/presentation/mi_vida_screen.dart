// TODO(i18n): hardcoded neutral Spanish, consistent with the domains /
// reminders / digest screens (they localize together in a later ARB pass).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/widgets.dart';
import '../../../theme/lifeos_palette.dart';
import '../../../theme/lifeos_tokens.dart';
import '../../daily_digest/domain/daily_digest.dart';
import '../../daily_digest/presentation/daily_digest_notifier.dart';
import '../../domains/domain/domain_descriptor.dart';
import '../../domains/domain/local_domain_entry.dart';
import '../../domains/domain/local_entry_config.dart';
import '../../domains/presentation/domain_entry_form.dart';
import '../../reminders/domain/local_reminder.dart';
import 'mi_vida_notifier.dart';

/// The unified "Mi vida" view: one scannable screen consolidating ALL saved
/// domain data (grouped by domain + person, newest first) and the
/// notifications (reminders + the daily digest), each entry editable/deletable
/// in place. Reachable from home and settings.
class MiVidaScreen extends ConsumerStatefulWidget {
  const MiVidaScreen({super.key});

  @override
  ConsumerState<MiVidaScreen> createState() => _MiVidaScreenState();
}

class _MiVidaScreenState extends ConsumerState<MiVidaScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ── Domain entry edit / delete ──────────────────────────────────────────────

  void _editEntry(String domainKey, LocalDomainEntry entry, LocalEntryType type) {
    final notifier = ref.read(miVidaNotifierProvider.notifier);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: kPageGutter,
          right: kPageGutter,
          top: Space.lg,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + Space.lg,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Editar: ${type.label}',
                  style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: Space.sm),
              DomainEntryForm(
                spec: type.fields,
                initialValues: {...entry.data, 'ts': entry.timestamp.toLocal()},
                submitLabel: 'Guardar cambios',
                onSubmit: (body) {
                  notifier.updateEntry(entry.uuid, type, body).then((ok) {
                    if (ok && sheetContext.mounted) Navigator.of(sheetContext).pop();
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteEntry(LocalDomainEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('¿Eliminar registro?'),
        content: Text(entry.label),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(miVidaNotifierProvider.notifier).deleteEntry(entry.uuid);
  }

  // ── Reminder edit ────────────────────────────────────────────────────────────

  Future<void> _editReminder(LocalReminder reminder) async {
    final controller = TextEditingController(text: reminder.text);
    var dueAt = reminder.dueAt;
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
                    final now = DateTime.now();
                    final date = await showDatePicker(
                      context: sheetContext,
                      initialDate: dueAt.isBefore(now) ? now : dueAt,
                      firstDate: now.subtract(const Duration(days: 1)),
                      lastDate: now.add(const Duration(days: 365 * 2)),
                    );
                    if (date == null || !sheetContext.mounted) return;
                    final time = await showTimePicker(
                      context: sheetContext,
                      initialTime: TimeOfDay.fromDateTime(dueAt),
                    );
                    if (time == null) return;
                    setSheetState(() => dueAt =
                        DateTime(date.year, date.month, date.day, time.hour, time.minute));
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
      await ref.read(miVidaNotifierProvider.notifier).editReminder(
            reminder,
            text: text.isEmpty ? reminder.text : text,
            dueAt: dueAt,
            recurrence: reminder.recurrence,
          );
    }
    controller.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(miVidaNotifierProvider);
    final notifier = ref.read(miVidaNotifierProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Mi vida')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
          child: RefreshIndicator(
            onRefresh: notifier.refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                  kPageGutter, Space.sm, kPageGutter, Space.xxxl),
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Buscar en todo…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: state.query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              notifier.setQuery('');
                            },
                          ),
                  ),
                  onChanged: notifier.setQuery,
                ),
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Text(state.error!,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.error)),
                  ),
                const SizedBox(height: Space.lg),
                const _DigestCard(),
                _NotificationsSection(
                  reminders: state.reminders,
                  onToggle: notifier.setReminderEnabled,
                  onEdit: _editReminder,
                  onDelete: notifier.deleteReminder,
                ),
                if (state.loading)
                  const Padding(
                    padding: EdgeInsets.all(Space.xxxl),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (state.sections.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(Space.xxl),
                    child: Text(
                      'Aún no hay datos guardados en este dispositivo.\n'
                      'Cuéntale algo a Axi en el chat, o entra a una categoría '
                      '(Salud, Ejercicio, Finanzas…) para registrarlo ahí.',
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  for (final section in state.sections)
                    _DomainSection(
                      section: section,
                      onEditEntry: _editEntry,
                      onDeleteEntry: _deleteEntry,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The daily digest card: schedule state + last summary snippet + quick
/// actions. Full management lives at `/settings/daily-digest`.
class _DigestCard extends ConsumerWidget {
  const _DigestCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(dailyDigestNotifierProvider);
    final notifier = ref.read(dailyDigestNotifierProvider.notifier);
    String two(int n) => n.toString().padLeft(2, '0');
    final schedule = state.schedule;
    final DailyDigest? digest = state.digest;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.panel),
        side: Theme.of(context).brightness == Brightness.dark
            ? BorderSide.none
            : BorderSide(color: LifeOSPalette.of(context).hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: LifeOSPalette.of(context).axiBubble,
                    borderRadius: BorderRadius.circular(Radii.chip),
                  ),
                  child: Icon(Icons.auto_awesome, size: 20,
                      color: LifeOSPalette.of(context).onAxiBubble),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Text('Resumen del día',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Switch(
                  value: schedule.enabled,
                  onChanged: notifier.setScheduleEnabled,
                ),
              ],
            ),
            Text(
              schedule.enabled
                  ? 'Automático a las ${two(schedule.hour)}:${two(schedule.minute)} (integrado, no se elimina).'
                  : 'Desactivado. Puedes reactivarlo cuando quieras.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (digest != null && (digest.wrapUp.isNotEmpty || digest.deterministicText.isNotEmpty)) ...[
              const SizedBox(height: Space.sm),
              Text(
                digest.wrapUp.isNotEmpty ? digest.wrapUp : digest.deterministicText,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: Space.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: state.isGenerating ? null : notifier.generate,
                  child: Text(state.isGenerating ? 'Preparando…' : 'Generar ahora'),
                ),
                const SizedBox(width: Space.sm),
                FilledButton.tonal(
                  onPressed: () => context.push('/settings/daily-digest'),
                  child: const Text('Ver / gestionar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Reminders (notifications) block: toggle on/off, edit, delete.
class _NotificationsSection extends StatelessWidget {
  const _NotificationsSection({
    required this.reminders,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final List<LocalReminder> reminders;
  final void Function(LocalReminder, bool) onToggle;
  final void Function(LocalReminder) onEdit;
  final void Function(LocalReminder) onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Recordatorios'),
        GroupedList(children: [
          if (reminders.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: Text('No tienes recordatorios en este dispositivo.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
            )
          else
            for (final reminder in reminders)
              _ReminderRow(
                reminder: reminder,
                onToggle: (v) => onToggle(reminder, v),
                onEdit: () => onEdit(reminder),
                onDelete: () => onDelete(reminder),
              ),
        ]),
      ],
    );
  }
}

class _ReminderRow extends StatelessWidget {
  const _ReminderRow({
    required this.reminder,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final LocalReminder reminder;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    String two(int n) => n.toString().padLeft(2, '0');
    final d = reminder.dueAt;
    final base = reminder.recurrence == ReminderRecurrence.daily
        ? 'Todos los días a las ${two(d.hour)}:${two(d.minute)}'
        : '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
    final subtitle = reminder.isDisabled
        ? '$base · desactivado'
        : (reminder.status == LocalReminderStatus.fired ? '$base · ya sonó' : base);
    return GroupedRow(
      icon: reminder.isDisabled ? Icons.notifications_off_outlined : Icons.alarm,
      title: reminder.text,
      subtitle: subtitle,
      showChevron: false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(value: !reminder.isDisabled, onChanged: onToggle),
          PopupMenuButton<String>(
            tooltip: 'Acciones',
            onSelected: (a) {
              if (a == 'edit') onEdit();
              if (a == 'delete') onDelete();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Editar')),
              PopupMenuItem(value: 'delete', child: Text('Eliminar')),
            ],
          ),
        ],
      ),
    );
  }
}

/// One domain block: header + per-person sub-groups.
class _DomainSection extends StatelessWidget {
  const _DomainSection({
    required this.section,
    required this.onEditEntry,
    required this.onDeleteEntry,
  });

  final DigestDomainSection section;
  final void Function(String domainKey, LocalDomainEntry entry, LocalEntryType type) onEditEntry;
  final void Function(LocalDomainEntry entry) onDeleteEntry;

  @override
  Widget build(BuildContext context) {
    final descriptor = domainDescriptorFor(section.domainKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Space.xxl),
        Semantics(
          header: true,
          label: '${section.domainTitle} · ${section.count}',
          excludeSemantics: true,
          child: Row(
            children: [
              Icon(descriptor.icon, size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: Space.sm),
              Flexible(child: Text(section.domainTitle,
                  style: Theme.of(context).textTheme.titleLarge)),
              const SizedBox(width: Space.sm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
                decoration: ShapeDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  shape: const StadiumBorder(),
                ),
                child: Text('${section.count}',
                    style: Theme.of(context).textTheme.labelMedium),
              ),
            ],
          ),
        ),
        for (final group in section.people) ...[
          SectionHeader(group.personLabel,
              padding: const EdgeInsets.fromLTRB(Space.xs, Space.md, Space.xs, Space.sm)),
          GroupedList(children: [
            for (final entry in group.entries)
              _EntryRow(
                entry: entry,
                editType: localEntryTypeFor(section.domainKey, entry.type),
                onEdit: (type) => onEditEntry(section.domainKey, entry, type),
                onDelete: () => onDeleteEntry(entry),
              ),
          ]),
        ],
      ],
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.editType,
    required this.onEdit,
    required this.onDelete,
  });

  final LocalDomainEntry entry;
  final LocalEntryType? editType;
  final void Function(LocalEntryType type) onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final local = entry.timestamp.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final when =
        '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
    final origin = editType != null ? editType!.label : 'Desde el chat';
    return GroupedRow(
      title: entry.label,
      subtitle: '$origin · $when',
      showChevron: false,
      trailing: PopupMenuButton<String>(
        tooltip: 'Acciones',
        onSelected: (action) {
          if (action == 'edit' && editType != null) onEdit(editType!);
          if (action == 'delete') onDelete();
        },
        itemBuilder: (context) => [
          if (editType != null) const PopupMenuItem(value: 'edit', child: Text('Editar')),
          const PopupMenuItem(value: 'delete', child: Text('Eliminar')),
        ],
      ),
    );
  }
}
