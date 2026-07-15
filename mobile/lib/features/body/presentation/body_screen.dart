import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/organ.dart';
import 'organs_notifier.dart';

/// "Axi's body" — the visible-soul slice. Mirrors the laptop dashboard's
/// clickable-organ avatar (`axi/src/axi/organs.py`) as a mobile list: one
/// expandable tile per organ, colored by `state`
/// (ok=green, degraded/planned=amber, down=red, off/unknown=muted grey).
class BodyScreen extends ConsumerWidget {
  const BodyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(organsNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('El cuerpo de Axi')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(organsNotifierProvider.notifier).refresh(),
        child: _buildBody(context, ref, state),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, OrgansUiState state) {
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
              onPressed: () => ref.read(organsNotifierProvider.notifier).refresh(),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (state.organs.isEmpty) {
      return const _ScrollableCenter(child: Text('Aún no hay órganos registrados.'));
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: state.organs.length,
      itemBuilder: (context, index) => _OrganTile(organ: state.organs[index]),
    );
  }
}

/// Wraps non-list content (loading/error/empty) in a scrollable so
/// [RefreshIndicator]'s pull-to-refresh keeps working.
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

/// Maps an organ's `state` to a display color. `unknown`/`off` share a
/// muted grey (neither is "wrong", just not actively reporting/enabled).
Color colorForOrganState(String state) {
  switch (state) {
    case 'ok':
      return Colors.green;
    case 'degraded':
    case 'planned':
      return Colors.amber;
    case 'down':
      return Colors.red;
    case 'off':
    case 'unknown':
    default:
      return Colors.grey;
  }
}

class _OrganTile extends StatelessWidget {
  const _OrganTile({required this.organ});

  final OrganState organ;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: Icon(Icons.circle, color: colorForOrganState(organ.state), size: 16),
      title: Text(organ.name),
      subtitle: Text(organ.detail),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(organ.description),
          ),
        ),
      ],
    );
  }
}
