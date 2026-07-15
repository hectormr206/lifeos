import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/offline_banner.dart';
import '../domain/domain_descriptor.dart';
import '../domain/domain_entry.dart';
import '../domain/domain_form_spec.dart';
import 'domain_entry_form.dart';
import 'domain_notifier.dart';

/// The generic domain data list screen (design D2's "generic data-table
/// widget"). ONE widget class instantiated per [DomainDescriptor] — all
/// per-domain differences live in data ([DomainEntry.raw]), never in widget
/// code. This slice is list/view + NL quick-capture only; structured
/// create/edit forms are a later slice (spec `mobile-domain-crud`).
class DomainListScreen extends ConsumerStatefulWidget {
  const DomainListScreen({required this.descriptor, super.key});

  final DomainDescriptor descriptor;

  @override
  ConsumerState<DomainListScreen> createState() => _DomainListScreenState();
}

class _DomainListScreenState extends ConsumerState<DomainListScreen> {
  final _captureController = TextEditingController();
  String? _lastShownCaptureError;

  @override
  void dispose() {
    _captureController.dispose();
    super.dispose();
  }

  void _capture() {
    final text = _captureController.text;
    if (text.trim().isEmpty) return;
    ref.read(domainNotifierProvider(widget.descriptor).notifier).capture(text);
    _captureController.clear();
  }

  /// Opens the structured create-entry form (spec structured-domain-forms)
  /// as a modal bottom sheet — the entry point for typed-field capture,
  /// alongside the NL quick-capture bar above. A [Consumer] inside the sheet
  /// keeps `creating`/`createError` reactive without rebuilding the whole
  /// screen. On success (including an offline-enqueued create — the
  /// repository never throws for that case), the sheet closes and the new
  /// entry is already visible at the top of the (optimistically-updated)
  /// list.
  void _openCreateForm() {
    final provider = domainNotifierProvider(widget.descriptor);
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
          child: Consumer(
            builder: (context, ref, _) {
              final state = ref.watch(provider);
              return DomainEntryForm(
                spec: domainFormSpecFor(widget.descriptor.key),
                submitting: state.creating,
                errorText: state.createError,
                onSubmit: (body) {
                  ref.read(provider.notifier).createEntry(body).then((ok) {
                    if (ok && sheetContext.mounted) Navigator.of(sheetContext).pop();
                  });
                },
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = domainNotifierProvider(widget.descriptor);
    final state = ref.watch(provider);

    ref.listen(provider, (previous, next) {
      if (next.captureError != null && next.captureError != _lastShownCaptureError) {
        _lastShownCaptureError = next.captureError;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.captureError!)));
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.descriptor.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.post_add),
            tooltip: 'Agregar registro',
            onPressed: _openCreateForm,
          ),
        ],
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(provider.notifier).refresh(),
              child: _buildBody(state),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _captureController,
                      decoration: const InputDecoration(
                        hintText: 'Registra algo… ej. "presión 120/80"',
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _capture(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: state.capturing
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.add),
                    tooltip: 'Registrar',
                    onPressed: state.capturing ? null : _capture,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(DomainUiState state) {
    if (state.loading) {
      return const _ScrollableCenter(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return _ScrollableCenter(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(state.error!),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => ref.read(domainNotifierProvider(widget.descriptor).notifier).refresh(),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (state.entries.isEmpty) {
      return const _ScrollableCenter(child: Text('Aún no hay registros.'));
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: state.entries.length,
      itemBuilder: (context, index) => _EntryTile(entry: state.entries[index]),
    );
  }
}

/// Wraps non-list content (loading/error/empty) in a scrollable so
/// [RefreshIndicator]'s pull-to-refresh keeps working even when the list is
/// short or absent.
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

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final DomainEntry entry;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(entry.title),
      subtitle: Text(_formatTimestamp(entry.timestamp)),
      trailing: entry.subject != null ? Chip(label: Text(entry.subject!)) : null,
    );
  }

  String _formatTimestamp(DateTime ts) {
    final local = ts.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
  }
}
