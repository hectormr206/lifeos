import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/offline_banner.dart';
import 'graph_search_notifier.dart';

/// The knowledge-graph browser — laptop `/brain3d` parity, minus the 3D:
/// search Axi's brain (server-side, over the FULL node table) and tap a
/// result to open its detail (facts, relations, provenance) at `/graph/:id`.
class GraphBrowserScreen extends ConsumerStatefulWidget {
  const GraphBrowserScreen({super.key});

  @override
  ConsumerState<GraphBrowserScreen> createState() => _GraphBrowserScreenState();
}

class _GraphBrowserScreenState extends ConsumerState<GraphBrowserScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search() => ref.read(graphSearchNotifierProvider.notifier).search(_controller.text);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(graphSearchNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Cerebro')),
      body: Column(
        children: [
          const OfflineBanner(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'Buscar en el cerebro…',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _search),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
            ),
          ),
          Expanded(child: _buildBody(state)),
        ],
      ),
    );
  }

  Widget _buildBody(GraphSearchUiState state) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return Center(child: Text(state.error!));
    }
    if (!state.searched) {
      return const Center(child: Text('Escribe algo para buscar en el cerebro.'));
    }
    if (state.results.isEmpty) {
      return const Center(child: Text('Sin resultados.'));
    }
    return ListView.builder(
      itemCount: state.results.length,
      itemBuilder: (context, index) {
        final node = state.results[index];
        return ListTile(
          title: Text(node.label),
          subtitle: Text(node.domain.isNotEmpty ? '${node.kind} · ${node.domain}' : node.kind),
          onTap: () => context.push('/graph/${node.id}'),
        );
      },
    );
  }
}
