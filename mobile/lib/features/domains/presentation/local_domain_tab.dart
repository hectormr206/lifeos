// TODO(i18n): hardcoded neutral Spanish pending the i18n sweep (the domains
// screens are not localized yet — they localize together in a later pass).
import '../../../core/widgets/widgets.dart';
import '../../../theme/lifeos_tokens.dart';
import 'package:lifeos/features/memory/domain/relationship_reminders.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_domain_repository.dart';
import '../domain/domain_descriptor.dart';
import '../domain/local_domain_entry.dart';
import '../domain/local_entry_config.dart';
import 'domain_entry_form.dart';
import 'local_domain_notifier.dart';

/// The LOCAL half of a domain screen (native on-device domain CRUD): entries
/// created/stored ON THIS DEVICE in the encrypted graph — no pairing, no
/// engine. ONE widget class for all 7 domains: the type chips, generated
/// form, filters and finance tiles all derive from `localEntryTypesByDomain`
/// + the descriptor (reusable-components principle; same tab pattern as
/// `LocalRemindersTab`).
class LocalDomainTab extends ConsumerStatefulWidget {
  const LocalDomainTab({required this.descriptor, super.key});

  final DomainDescriptor descriptor;

  @override
  ConsumerState<LocalDomainTab> createState() => _LocalDomainTabState();
}

class _LocalDomainTabState extends ConsumerState<LocalDomainTab> {
  final _searchController = TextEditingController();

  List<LocalEntryType> get _types => localEntryTypesFor(widget.descriptor.key);

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ── Create / edit / delete ────────────────────────────────────────────────

  /// FAB "+": one type → straight to its form; several → a type picker first.
  Future<void> _openCreate() async {
    final types = _types;
    if (types.isEmpty) return;
    final type = types.length == 1 ? types.first : await _pickType(types);
    if (type == null || !mounted) return;
    _openForm(type: type);
  }

  Future<LocalEntryType?> _pickType(List<LocalEntryType> types) {
    return showModalBottomSheet<LocalEntryType>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(kPageGutter),
              child: Text('¿Qué quieres registrar?', style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            for (final type in types)
              ListTile(
                title: Text(type.label),
                onTap: () => Navigator.of(sheetContext).pop(type),
              ),
          ],
        ),
      ),
    );
  }

  /// The ONE generated form, in a bottom sheet — create when [entry] is
  /// null, edit (same uuid) otherwise.
  void _openForm({required LocalEntryType type, LocalDomainEntry? entry}) {
    final notifier = ref.read(localDomainNotifierProvider(widget.descriptor).notifier);
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
              Text(
                entry == null ? type.label : 'Editar: ${type.label}',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: Space.sm),
              DomainEntryForm(
                spec: type.fields,
                initialValues: entry == null ? null : {...entry.data, 'ts': entry.timestamp.toLocal()},
                submitLabel: entry == null ? 'Guardar' : 'Guardar cambios',
                onSubmit: (body) {
                  final result = entry == null
                      ? notifier.create(type, body)
                      : notifier.update(entry.uuid, type, body);
                  result.then((ok) {
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

  Future<void> _confirmDelete(LocalDomainEntry entry) async {
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
    await ref.read(localDomainNotifierProvider(widget.descriptor).notifier).delete(entry.uuid);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = localDomainNotifierProvider(widget.descriptor);
    final state = ref.watch(provider);
    final notifier = ref.read(provider.notifier);

    return Scaffold(
      floatingActionButton: _types.isEmpty
          ? null
          : FloatingActionButton(
              tooltip: 'Agregar registro',
              onPressed: _openCreate,
              child: const Icon(Icons.add),
            ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
          child: Column(
            children: [
              if (state.error != null && state.entries.isNotEmpty)
                MaterialBanner(
                  content: Text(state.error!),
                  actions: [TextButton(onPressed: notifier.refresh, child: const Text('Reintentar'))],
                ),
              if (widget.descriptor.key == 'finance' && state.summary != null)
                _FinanceSummaryTiles(summary: state.summary!),
              if (state.reminders != null && !state.reminders!.isEmpty)
                _RelationshipReminders(reminders: state.reminders!)
              // Nothing to remind about YET, but this is the domain where the
              // whole point is invisible until you start: the card used to
              // collapse and take with it the only trace that any of it existed
              // ("estoy en blanco en esto"). A feature you cannot find is a
              // feature you do not have.
              else if (widget.descriptor.key == 'relationships')
                const _RelationshipsInvitation(),
              Padding(
                padding: const EdgeInsets.fromLTRB(kPageGutter, Space.sm, kPageGutter, 0),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Buscar…',
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
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(kPageGutter, Space.md, kPageGutter, 0),
                child: SegmentedButton<LocalEntryPeriod>(
                  segments: [
                    for (final period in LocalEntryPeriod.values)
                      ButtonSegment(value: period, label: Text(period.label)),
                  ],
                  selected: {state.period},
                  onSelectionChanged: (selection) => notifier.setPeriod(selection.first),
                ),
              ),
              if (_types.isNotEmpty)
                SizedBox(
                  height: Space.huge,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: kPageGutter, vertical: Space.xs),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: Space.sm),
                        child: ChoiceChip(
                          label: const Text('Todos'),
                          selected: state.typeFilter == null,
                          onSelected: (_) => notifier.setTypeFilter(null),
                        ),
                      ),
                      for (final type in _types)
                        Padding(
                          padding: const EdgeInsets.only(right: Space.sm),
                          child: ChoiceChip(
                            label: Text(type.label),
                            selected: state.typeFilter == type.type,
                            onSelected: (_) => notifier.setTypeFilter(type.type),
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: notifier.refresh,
                  child: _buildList(state),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(LocalDomainUiState state) {
    if (state.loading) {
      return const ScrollableCenter(child: CircularProgressIndicator());
    }
    if (state.error != null && state.entries.isEmpty) {
      return ScrollableCenter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: kPageGutter),
          child: Text(state.error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (state.entries.isEmpty) {
      // The relationships invitation can leave less height than the empty
      // state needs. Center when it fits; otherwise keep the whole state
      // reachable by scrolling, with pull-to-refresh still available.
      return LayoutBuilder(
        builder: (context, constraints) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: const Padding(
                padding: EdgeInsets.all(kPageGutter),
                child: EmptyState(
                  icon: Icons.inbox_outlined,
                  title: 'Aún no hay registros en este dispositivo.',
                  message: 'Usa el botón + para agregar el primero.',
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Grouped by LOCAL calendar day, newest first (entries arrive sorted).
    final rows = <Widget>[];
    DateTime? currentDay;
    var entries = <Widget>[];
    for (final entry in state.entries) {
      final local = entry.timestamp.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (currentDay != day) {
        currentDay = day;
        if (entries.isNotEmpty) rows.add(GroupedList(children: entries));
        entries = <Widget>[];
        rows.add(_DayHeader(day: day));
      }
      entries.add(_EntryRow(
        entry: entry,
        editType: localEntryTypeFor(widget.descriptor.key, entry.type),
        onEdit: (type) => _openForm(type: type, entry: entry),
        onDelete: () => _confirmDelete(entry),
      ));
    }
    if (entries.isNotEmpty) rows.add(GroupedList(children: entries));
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(kPageGutter, 0, kPageGutter, Space.huge + Space.huge), // keep the FAB off the last row
      children: rows,
    );
  }
}

/// Gastos / Ingresos / Balance tiles for the ACTIVE period (finance only) —
/// the laptop dashboard's summary strip, on-device.
class _FinanceSummaryTiles extends StatelessWidget {
  const _FinanceSummaryTiles({required this.summary});

  final FinanceSummary summary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPageGutter, Space.sm, kPageGutter, 0),
      child: Row(
        children: [
          _tile(context, 'Gastos', summary.gastos, scheme.error),
          const SizedBox(width: Space.sm),
          _tile(context, 'Ingresos', summary.ingresos, scheme.primary),
          const SizedBox(width: Space.sm),
          _tile(context, 'Balance', summary.balance, summary.balance < 0 ? scheme.error : scheme.primary),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, String label, double value, Color color) {
    return Expanded(
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.md, horizontal: Space.sm),
          child: Column(
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: Space.xs),
              Text(
                '\$${value.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final String text;
    if (day == today) {
      text = 'Hoy';
    } else if (day == today.subtract(const Duration(days: 1))) {
      text = 'Ayer';
    } else {
      String two(int n) => n.toString().padLeft(2, '0');
      text = '${two(day.day)}/${two(day.month)}/${day.year}';
    }
    return SectionHeader(text);
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

  /// Non-null when the entry's `data.type` maps to a known config type —
  /// only then is EDIT offered (untyped chat facts stay delete-only).
  final LocalEntryType? editType;
  final void Function(LocalEntryType type) onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final local = entry.timestamp.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final subtitle = editType != null
        ? '${editType!.label} · ${two(local.hour)}:${two(local.minute)}'
        : 'Desde el chat · ${two(local.hour)}:${two(local.minute)}';
    return GroupedRow(
      title: entry.label,
      subtitle: subtitle,
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

/// Relaciones: the birthdays coming up and the people worth writing to.
///
/// This is the point of recording a person at all. Until now the app could
/// store one and then never mention them again — the birthday and nudge rules
/// existed but nothing called them, so the feature was invisible.
///
/// TWO QUESTIONS, ANSWERED ONCE EACH. A nudge answers "who should I write to",
/// and the birthday behind it is its reason; the birthday list answers "what is
/// coming up". A birthday that is already a nudge's reason is therefore NOT
/// repeated in the list below — printing the same sentence twice reads as a
/// bug, and makes the user hunt for a difference that is not there.
///
/// The reason is always a reason, never a countdown. "Hace 45 días que no
/// hablas con Juan" is administrative guilt and gets muted within a week;
/// "Sofía cumple 7 el 10" is something to write about. The day count decides
/// who appears here and is never rendered.
class _RelationshipReminders extends StatelessWidget {
  const _RelationshipReminders({required this.reminders});

  final RelationshipReminders reminders;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final hint = scheme.onSurfaceVariant;

    // Birthdays already carried by a nudge, so they are not printed twice.
    final claimed = <String>{
      for (final d in reminders.due)
        if (d.context != null) '${d.context!.person.name}::${d.context!.on}',
    };
    final unclaimed = [
      for (final b in reminders.birthdays)
        if (!claimed.contains('${b.person.name}::${b.on}')) b,
    ];

    if (reminders.due.isEmpty && unclaimed.isEmpty && reminders.loveLanguages == null) {
      // The caller decides what to show instead — see the `else if` in
      // build(). Two places deciding the same thing is how they drift apart.
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(kPageGutter, Space.sm, kPageGutter, 0),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final d in reminders.due)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.waving_hand_outlined, size: 20, color: scheme.primary),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // WHO to write to. The reason alone left the user
                          // reading a birthday with no idea whose it made
                          // relevant, or what they were meant to do about it.
                          Text('Escríbele a ${d.person.name}',
                              style: textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          Text(d.message(),
                              style: textTheme.bodySmall?.copyWith(color: hint)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (reminders.due.isNotEmpty && unclaimed.isNotEmpty)
              const SizedBox(height: Space.xxl),
            for (final b in unclaimed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.cake_outlined, size: 20, color: scheme.primary),
                    const SizedBox(width: Space.md),
                    Expanded(child: Text(b.describe(), style: textTheme.bodyMedium)),
                  ],
                ),
              ),
            // THE COUPLE OBSERVATION, set apart on purpose.
            //
            // It is not a reminder and must not read like one: nothing to do,
            // no one to write to, no date. It is a thing to sit with — the
            // one thing a person cannot see from inside, because from inside
            // it is obvious you are showing love. You are. Just in your own
            // language. Rendered quiet and last so it never competes with the
            // actionable rows above.
            if (reminders.loveLanguages != null) ...[
              const SizedBox(height: Space.xxl),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.favorite_outline, size: 18, color: hint),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Text(
                        reminders.loveLanguages!.describe(),
                        style: textTheme.bodySmall?.copyWith(
                          color: hint,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}


/// Shown in Relaciones before anything has been registered.
class _RelationshipsInvitation extends StatelessWidget {
  const _RelationshipsInvitation();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(kPageGutter, Space.sm, kPageGutter, 0),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.favorite_border,
                    size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: Space.md),
                Text('Personas y pareja', style: text.titleSmall),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Aquí viven las personas que te importan. Guarda su fecha de '
              'nacimiento y te aviso unos días antes del cumpleaños, en todos '
              'tus dispositivos. Y si me dices cada cuánto te gustaría '
              'buscarlas, te lo recuerdo — sin que tengas que acordarte tú.',
              style: text.bodySmall,
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Y con "Pareja" puedes ir anotando lo que hiciste por ella y lo '
              'que ella te dijo que le gustó. Con el tiempo se nota qué es lo '
              'que de verdad valora — que casi nunca es lo que uno supone.',
              style: text.bodySmall,
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Empieza con el botón de abajo, o cuéntaselo a Axi en el chat.',
              style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
