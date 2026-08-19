import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/graph/graph_providers.dart';
import '../../../core/graph/graph_records.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/brain3d_payload.dart';
import '../domain/brain3d_filters.dart';
import '../domain/brain3d_news.dart';
import '../domain/brain3d_palette.dart';
import 'brain3d_layout.dart';
import 'brain3d_view.dart';

/// The Cerebro 3D payload built from the ON-DEVICE graph (read side only).
/// A plain FutureProvider — recomputed on each screen entry via `ref.refresh`
/// is unnecessary: autoDispose drops it when the screen closes so the next
/// visit re-reads the (possibly grown) local graph.
final brain3dPayloadProvider = FutureProvider.autoDispose<Brain3dPayload>((
  ref,
) async {
  final store = await ref.watch(localGraphStoreProvider.future);
  return buildBrain3dPayload(store);
});

/// Cerebro 3D — mobile parity of the laptop's /brain3d: an interactive
/// force-directed 3D rendering of the user's LOCAL memory graph so "Axi está
/// relacionando todo lo que le cuentas" is visible on the phone too.
///
/// Rendered natively by a CustomPainter, NOT a WebView: the same widget runs
/// on the Pixel, on Linux and in the widget tests, so the two devices cannot
/// disagree about how the same synced graph looks — which is exactly what a
/// per-platform renderer produced before.
class Brain3dScreen extends ConsumerStatefulWidget {
  const Brain3dScreen({super.key});

  @override
  ConsumerState<Brain3dScreen> createState() => _Brain3dScreenState();
}

class _Brain3dScreenState extends ConsumerState<Brain3dScreen> {
  /// The node whose details are open. Null closes the panel and clears every
  /// label, which is what makes the graph readable again.
  String? _selectedId;

  /// Search box, domain and date — the controls the desktop Cerebro has always
  /// had, and the difference between a picture and a tool at 88 nodes.
  Brain3dFilter _filter = const Brain3dFilter();
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final payload = ref.watch(brain3dPayloadProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E13),
      appBar: AppBar(
        title: Text(l10n.brain3dTitle),
        // The count, as the desktop Cerebro has always shown it. Without it a
        // sparse-looking graph is indistinguishable from a broken one — which
        // cost this session two wrong fixes.
        actions: [
          if (payload case AsyncData(:final value))
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${value.nodes.length} · ${value.edges.length}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ),
        ],
      ),
      body: switch (payload) {
        AsyncData(:final value) => _Brain(
          payload: value,
          filter: _filter,
          searchController: _searchController,
          selectedId: _selectedId,
          onFilter: (f) => setState(() {
            _filter = f;
            // A node hidden by a filter must not keep its panel open: the
            // details would describe something no longer on screen.
            _selectedId = null;
          }),
          onSelect: (id) => setState(() => _selectedId = id),
          onForget: (uuid) async {
            final store = await ref.read(localGraphStoreProvider.future);
            await store.softDeleteNode(uuid);
            if (!mounted) return;
            setState(() => _selectedId = null);
            ref.invalidate(brain3dPayloadProvider);
          },
          onMerge: (loser, winner) async {
            final store = await ref.read(localGraphStoreProvider.future);
            await store.mergeNodes(loserUuid: loser, winnerUuid: winner);
            if (!mounted) return;
            ref.invalidate(brain3dPayloadProvider);
          },
        ),
        AsyncError(:final error) => Center(
          child: Text('$error', style: const TextStyle(color: Colors.white70)),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _Brain extends StatelessWidget {
  const _Brain({
    required this.payload,
    required this.filter,
    required this.searchController,
    required this.selectedId,
    required this.onFilter,
    required this.onSelect,
    required this.onForget,
    required this.onMerge,
  });

  final Brain3dPayload payload;
  final Brain3dFilter filter;
  final TextEditingController searchController;
  final String? selectedId;
  final void Function(Brain3dFilter) onFilter;
  final void Function(String?) onSelect;
  final Future<void> Function(String uuid) onForget;
  final Future<void> Function(String loser, String winner) onMerge;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final visible = applyBrain3dFilter(payload.nodes, filter, now: now);
    final visibleIds = {for (final n in visible) n.uuid};
    final edges = [
      for (final e in payload.edges)
        if (visibleIds.contains(e.srcUuid) && visibleIds.contains(e.dstUuid))
          (e.srcUuid, e.dstUuid),
    ];
    final domains = <String>{
      for (final n in payload.nodes)
        if (n.domain != null && n.domain!.isNotEmpty) n.domain!,
    }.toList()..sort();

    final placement = brain3dPanelPlacement(MediaQuery.sizeOf(context));
    final selected = selectedId == null
        ? null
        : visible.where((n) => n.uuid == selectedId).firstOrNull;

    final graph = Stack(
      children: [
        Positioned.fill(
          child: visible.length < 3
              ? _Sparse(count: visible.length, filtered: filter.isActive)
              : Brain3dView(
                  selectedId: selectedId,
                  onSelect: onSelect,
                  nodes: [
                    for (final n in visible)
                      Brain3dVisualNode(
                        id: n.uuid,
                        label: n.label,
                        color: brain3dColorFor(domain: n.domain, kind: n.kind),
                      ),
                  ],
                  edges: edges,
                ),
        ),
        if (domains.isNotEmpty)
          Positioned(
            left: 12,
            top: 12,
            child: _DomainList(
              domains: domains,
              selected: filter.domain,
              onPick: (d) => onFilter(
                d == null
                    ? filter.copyWith(clearDomain: true)
                    : filter.copyWith(domain: d),
              ),
            ),
          ),
        const Positioned(left: 12, bottom: 12, child: _Hint()),
      ],
    );

    final news = brain3dWeeklyNews(payload.nodes, now: now);
    final details = _Details(
      node: selected,
      // The news read from the WHOLE graph, not the filtered view: they answer
      // "what did Axi learn this week", a question a domain filter does not
      // change the answer to.
      news: news,
      others: [
        for (final n in visible)
          if (n.uuid != selectedId) n,
      ],
      onClose: () => onSelect(null),
      onSelect: onSelect,
      onForget: onForget,
      onMerge: onMerge,
    );

    return Column(
      children: [
        _Controls(
          controller: searchController,
          filter: filter,
          shown: visible.length,
          total: payload.nodes.length,
          relations: edges.length,
          onFilter: onFilter,
        ),
        Expanded(
          child: placement == Brain3dPanelPlacement.side
              ? Row(
                  children: [
                    Expanded(child: graph),
                    SizedBox(width: 320, child: details),
                  ],
                )
              : LayoutBuilder(
                  builder: (context, constraints) => Column(
                    children: [
                      Expanded(child: graph),
                      // Beside the graph, never on top of it: floating, the
                      // panel hid the bottom of the layout and edges ran off
                      // under it. The graph gets what is left, so it FITS
                      // itself to the space it actually has.
                      if (selected != null || news.isNotEmpty)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: constraints.maxHeight * 0.42,
                          ),
                          child: details,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// Search box, date chips and the counts — the row across the top of the
/// original.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.controller,
    required this.filter,
    required this.shown,
    required this.total,
    required this.relations,
    required this.onFilter,
  });

  final TextEditingController controller;
  final Brain3dFilter filter;
  final int shown;
  final int total;
  final int relations;
  final void Function(Brain3dFilter) onFilter;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white),
            onChanged: (q) => onFilter(filter.copyWith(query: q)),
            decoration: InputDecoration(
              hintText: 'Buscar en tu memoria…',
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search, color: Colors.white38),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, color: Colors.white38),
                      onPressed: () {
                        controller.clear();
                        onFilter(filter.copyWith(query: ''));
                      },
                    ),
              filled: true,
              fillColor: const Color(0xFF161A22),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Text('Fecha:', style: TextStyle(color: Colors.white54)),
                const SizedBox(width: 8),
                for (final entry in const [
                  (Brain3dDateRange.all, 'Todo'),
                  (Brain3dDateRange.today, 'Hoy'),
                  (Brain3dDateRange.week, 'Esta semana'),
                  (Brain3dDateRange.month, 'Este mes'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(entry.$2),
                      selected: filter.range == entry.$1,
                      onSelected: (_) =>
                          onFilter(filter.copyWith(range: entry.$1)),
                      backgroundColor: const Color(0xFF161A22),
                      selectedColor: const Color(0xFF12D6A0),
                      labelStyle: TextStyle(
                        color: filter.range == entry.$1
                            ? Colors.black
                            : Colors.white70,
                        fontSize: 12,
                      ),
                      side: BorderSide.none,
                      showCheckmark: false,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            // Shown AND total when a filter hides some: "12 de 88" is the only
            // way to tell a filtered graph from a lost one.
            shown == total
                ? '$total nodos · $relations relaciones'
                : '$shown de $total nodos · $relations relaciones',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// The floating domain list of the original, over the top-left of the graph.
class _DomainList extends StatelessWidget {
  const _DomainList({
    required this.domains,
    required this.selected,
    required this.onPick,
  });

  final List<String> domains;
  final String? selected;
  final void Function(String?) onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xCC161A22),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                'Dominio',
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => onPick(null),
                child: Text(
                  'Todos',
                  style: TextStyle(
                    color: selected == null
                        ? const Color(0xFF12D6A0)
                        : Colors.white54,
                  ),
                ),
              ),
            ],
          ),
          for (final d in domains)
            GestureDetector(
              onTap: () => onPick(selected == d ? null : d),
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '· ${brain3dDomainLabel(d)}',
                  style: TextStyle(
                    color: selected == d
                        ? const Color(0xFF12D6A0)
                        : Colors.white70,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xAA161A22),
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Text(
      'Orbitar: arrastrar · Zoom: pellizcar · Toca: seleccionar',
      style: TextStyle(color: Colors.white38, fontSize: 11),
    ),
  );
}

/// Empty/sparse state, with the reason.
class _Sparse extends StatelessWidget {
  const _Sparse({required this.count, required this.filtered});

  final int count;
  final bool filtered;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Text(
        filtered
            // Says the FILTER is the reason, not an empty memory — the
            // difference between "nothing matched" and "you have nothing".
            ? 'Nada que dibujar con estos filtros ($count de tus memorias '
                  'coinciden). Quita alguno para ver el grafo completo.'
            : count == 0
            // The original copy for a genuinely empty brain, kept
            // because it is warmer than anything I would write to
            // replace it.
            ? AppLocalizations.of(context).brain3dEmpty
            : 'Por ahora Axi recuerda $count cosa(s). Un cerebro '
                  'necesita al menos tres para dibujar relaciones — '
                  'contale un par más y esta pantalla cobra vida.',
        style: const TextStyle(color: Colors.white70, fontSize: 16),
        textAlign: TextAlign.center,
      ),
    ),
  );
}

/// The details column of the original: the week's news until something is
/// selected, then that memory and the two things you can do to it.
class _Details extends StatelessWidget {
  const _Details({
    required this.node,
    required this.news,
    required this.others,
    required this.onClose,
    required this.onSelect,
    required this.onForget,
    required this.onMerge,
  });

  final GraphNodeRecord? node;
  final List<GraphNodeRecord> news;
  final List<GraphNodeRecord> others;
  final VoidCallback onClose;
  final void Function(String?) onSelect;
  final Future<void> Function(String uuid) onForget;
  final Future<void> Function(String loser, String winner) onMerge;

  @override
  Widget build(BuildContext context) {
    final n = node;
    final text = Theme.of(context).textTheme;

    if (n == null) {
      return Material(
        key: const ValueKey('brain3d-panel'),
        color: const Color(0xFF11151C),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  news.isEmpty
                      ? 'Toca un nodo para ver sus detalles'
                      : 'Novedades de la semana',
                  style: text.titleSmall?.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                // Bounded: on a phone this panel floats over the graph, and a
                // list that grows with the week would swallow it.
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final item in news)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.circle,
                            size: 10,
                            color: brain3dColorFor(
                              domain: item.domain,
                              kind: item.kind,
                            ),
                          ),
                          title: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: Text(
                            _day(item.occurredAt ?? item.createdAt),
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                          onTap: () => onSelect(item.uuid),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      key: const ValueKey('brain3d-panel'),
      color: const Color(0xFF161A22),
      child: SafeArea(
        top: false,
        // Scrollable, because the panel is capped so it cannot eat the graph:
        // on a short screen the buttons would otherwise fall off the bottom
        // edge, which is the same thing as not having them.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      n.label,
                      style: text.titleMedium?.copyWith(color: Colors.white),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: onClose,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final tag in [n.kind, ?n.domain])
                    Chip(
                      label: Text(brain3dDomainLabel(tag)),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: const Color(0xFF222833),
                      labelStyle: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                      side: BorderSide.none,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Creado: ${_day(n.createdAt)}',
                style: text.bodySmall?.copyWith(color: Colors.white54),
              ),
              if (n.occurredAt != null)
                Text(
                  'Fecha: ${_day(n.occurredAt!)}',
                  style: text.bodySmall?.copyWith(color: Colors.white54),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.merge, size: 18),
                    label: const Text('Fusionar con…'),
                    onPressed: others.isEmpty
                        ? null
                        : () => _pickMerge(context, n),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Olvidar este nodo'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                    ),
                    onPressed: () => _confirmForget(context, n),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Picks the DUPLICATE to fold in. The node on screen survives — whichever
  /// one wins keeps its label, so getting this backwards would silently
  /// rename the user's own memory.
  Future<void> _pickMerge(BuildContext context, GraphNodeRecord keep) async {
    final loser = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF161A22),
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '¿Cuál es el mismo que "${keep.label}"?',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final other in others)
                    ListTile(
                      title: Text(
                        other.label,
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () => Navigator.of(context).pop(other.uuid),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (loser != null) await onMerge(loser, keep.uuid);
  }

  /// Asks before removing. This is the one tap in the app that erases
  /// something the user told Axi — and it erases it on every device.
  Future<void> _confirmForget(BuildContext context, GraphNodeRecord n) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('¿Olvidar "${n.label}"?'),
        content: const Text(
          'Se quitará de tu memoria y de todos tus dispositivos, junto con sus '
          'relaciones.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Olvidar'),
          ),
        ],
      ),
    );
    if (yes ?? false) await onForget(n.uuid);
  }

  static String _day(DateTime t) => '${t.day}/${t.month}/${t.year}';
}
