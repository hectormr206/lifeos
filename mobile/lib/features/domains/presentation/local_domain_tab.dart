// TODO(i18n): hardcoded neutral Spanish pending the i18n sweep (the domains
// screens are not localized yet — they localize together in a later pass).
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
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('¿Qué quieres registrar?', style: TextStyle(fontWeight: FontWeight.bold)),
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
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
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
              const SizedBox(height: 8),
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
      body: Column(
        children: [
          if (state.error != null && state.entries.isNotEmpty)
            MaterialBanner(
              content: Text(state.error!),
              actions: [TextButton(onPressed: notifier.refresh, child: const Text('Reintentar'))],
            ),
          if (widget.descriptor.key == 'finance' && state.summary != null)
            _FinanceSummaryTiles(summary: state.summary!),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Buscar…',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
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
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
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
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: const Text('Todos'),
                      selected: state.typeFilter == null,
                      onSelected: (_) => notifier.setTypeFilter(null),
                    ),
                  ),
                  for (final type in _types)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
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
    );
  }

  Widget _buildList(LocalDomainUiState state) {
    if (state.loading) {
      return const _ScrollableCenter(child: CircularProgressIndicator());
    }
    if (state.error != null && state.entries.isEmpty) {
      return _ScrollableCenter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(state.error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (state.entries.isEmpty) {
      return const _ScrollableCenter(
        child: Text('Aún no hay registros en este teléfono.\nUsa el botón + para agregar el primero.',
            textAlign: TextAlign.center),
      );
    }

    // Grouped by LOCAL calendar day, newest first (entries arrive sorted).
    final rows = <Widget>[];
    DateTime? currentDay;
    for (final entry in state.entries) {
      final local = entry.timestamp.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (currentDay != day) {
        currentDay = day;
        rows.add(_DayHeader(day: day));
      }
      rows.add(_EntryRow(
        entry: entry,
        editType: localEntryTypeFor(widget.descriptor.key, entry.type),
        onEdit: (type) => _openForm(type: type, entry: entry),
        onDelete: () => _confirmDelete(entry),
      ));
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 88), // keep the FAB off the last row
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          _tile(context, 'Gastos', summary.gastos, scheme.error),
          const SizedBox(width: 8),
          _tile(context, 'Ingresos', summary.ingresos, scheme.primary),
          const SizedBox(width: 8),
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
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Column(
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: Theme.of(context).textTheme.labelLarge),
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
    return ListTile(
      title: Text(entry.label),
      subtitle: Text(subtitle),
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
