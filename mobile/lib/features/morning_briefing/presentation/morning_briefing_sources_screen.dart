import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/briefing_source.dart';
import 'morning_briefing_notifier.dart';

/// Editor for the ON-DEVICE briefing's news sources, grouped by SECTION.
///
/// A flat list of URLs stops being readable the moment it grows: nobody can
/// tell what "https://blog.desdelinux.net/feed/" is for, or decide whether to
/// drop it, next to fifteen others. The section is the name the user gives a
/// shelf, and typing one that already exists files the feed there rather than
/// creating a near-duplicate heading.
class MorningBriefingSourcesScreen extends ConsumerStatefulWidget {
  const MorningBriefingSourcesScreen({super.key});

  @override
  ConsumerState<MorningBriefingSourcesScreen> createState() =>
      _MorningBriefingSourcesScreenState();
}

class _MorningBriefingSourcesScreenState
    extends ConsumerState<MorningBriefingSourcesScreen> {
  final _controller = TextEditingController();
  final _sectionController = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _sectionController.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    final section = _sectionController.text.trim();
    await ref
        .read(morningBriefingNotifierProvider.notifier)
        .addSource(
          url,
          section: section.isEmpty ? kDefaultBriefingSection : section,
        );
    _controller.clear();
    // The section stays: someone adding three Linux feeds types it once.
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
            child: Column(
              children: [
                TextField(
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
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _sectionController,
                        decoration: const InputDecoration(
                          labelText: 'Sección',
                          hintText: 'Mundo, México, Linux…',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _add, child: const Text('Agregar')),
                  ],
                ),
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
                : ListView(
                    children: [
                      for (final entry in groupBriefingSources(
                        sources,
                      ).entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(
                            '${entry.key} · ${entry.value.length}',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        for (final source in entry.value)
                          ListTile(
                            leading: const Icon(Icons.rss_feed),
                            title: Text(
                              source.url,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Eliminar',
                              onPressed: () => ref
                                  .read(
                                    morningBriefingNotifierProvider.notifier,
                                  )
                                  .removeSource(source.url),
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
