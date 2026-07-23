import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'morning_briefing_notifier.dart';

/// Editor for the ON-DEVICE briefing's news-source URLs: add (RSS/Atom feeds or
/// article pages) and remove. Changes persist via shared_preferences through
/// the notifier.
class MorningBriefingSourcesScreen extends ConsumerStatefulWidget {
  const MorningBriefingSourcesScreen({super.key});

  @override
  ConsumerState<MorningBriefingSourcesScreen> createState() => _MorningBriefingSourcesScreenState();
}

class _MorningBriefingSourcesScreenState extends ConsumerState<MorningBriefingSourcesScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    await ref.read(morningBriefingNotifierProvider.notifier).addSource(url);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(morningBriefingNotifierProvider).sources;

    return Scaffold(
      appBar: AppBar(title: const Text('Fuentes del boletín')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'URL de la fuente',
                      hintText: 'https://ejemplo.com/rss',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _add, child: const Text('Agregar')),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Se admiten feeds RSS/Atom o páginas de noticias. '
                'Una fuente que falle se omite sin afectar al resto.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
          const Divider(height: 24),
          Expanded(
            child: sources.isEmpty
                ? const Center(child: Text('No hay fuentes configuradas.'))
                : ListView.builder(
                    itemCount: sources.length,
                    itemBuilder: (context, index) {
                      final url = sources[index];
                      return ListTile(
                        leading: const Icon(Icons.rss_feed),
                        title: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Eliminar',
                          onPressed: () => ref.read(morningBriefingNotifierProvider.notifier).removeSource(url),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
