import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../domain/domain_descriptor.dart';

/// The domains hub (spec `mobile-domain-crud` / `mobile-app-shell`): a grid
/// of the registered domains (health, finance, exercise this slice — the
/// same grid grows to 7 by extending [domainDescriptors], no widget
/// changes). Tapping a card opens that domain's [DomainListScreen] at
/// `/domains/:key`. Paired-only, gated in go_router the same way as `/chat`.
class DomainsHubScreen extends StatelessWidget {
  const DomainsHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mis datos')),
      body: GridView.count(
        padding: const EdgeInsets.all(16),
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        children: [
          for (final descriptor in domainDescriptors)
            _DomainCard(descriptor: descriptor, onTap: () => context.push('/domains/${descriptor.key}')),
        ],
      ),
    );
  }
}

class _DomainCard extends StatelessWidget {
  const _DomainCard({required this.descriptor, required this.onTap});

  final DomainDescriptor descriptor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(descriptor.icon, size: 36),
            const SizedBox(height: 8),
            Text(descriptor.title),
          ],
        ),
      ),
    );
  }
}
