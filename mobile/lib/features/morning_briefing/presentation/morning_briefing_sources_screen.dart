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

  /// Picked from a fixed list, not typed: free text produced "Tecnologia",
  /// "tecnología" and "Tech" as three shelves for one idea, and the person who
  /// had to live with that mess was the user.
  String _section = kDefaultBriefingSection;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;

    await ref
        .read(morningBriefingNotifierProvider.notifier)
        .addSource(url, section: _section);
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
                      child: DropdownButtonFormField<String>(
                        initialValue: _section,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Sección',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final section in kBriefingSections)
                            DropdownMenuItem(
                              value: section,
                              child: Text(section),
                            ),
                        ],
                        onChanged: (value) => setState(
                          () => _section = value ?? kDefaultBriefingSection,
                        ),
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
                              style: source.enabled
                                  ? null
                                  : TextStyle(
                                      color: Theme.of(context).disabledColor,
                                      decoration: TextDecoration.lineThrough,
                                    ),
                            ),
                            // Disabled sources stay visible, or there would be
                            // no way to turn one back on.
                            subtitle: source.enabled
                                ? null
                                : const Text('Desactivada'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: source.enabled,
                                  onChanged: (on) => ref
                                      .read(
                                        morningBriefingNotifierProvider
                                            .notifier,
                                      )
                                      .setSourceEnabled(source.url, on),
                                ),
                                // Only the user's own can be deleted: a shipped
                                // source that is gone means going to find the
                                // URL again, which nobody does.
                                if (source.canDelete)
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: 'Eliminar',
                                    onPressed: () => ref
                                        .read(
                                          morningBriefingNotifierProvider
                                              .notifier,
                                        )
                                        .removeSource(source.url),
                                  ),
                              ],
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
