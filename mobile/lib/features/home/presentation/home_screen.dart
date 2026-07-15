import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../connection/domain/connection_status.dart';
import '../../connection/presentation/connection_notifier.dart';
import 'home_providers.dart';

/// Foundation home screen (design D1 / M0->M1 bridge; spec
/// mobile-app-shell, M1 slice 1): shows the connection status to the
/// paired engine and a CTA to connect when unpaired. Deliberately NOT a
/// chat/domain UI — that is the next slice.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('LifeOS'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Conexión',
            onPressed: () => context.push('/settings/connection'),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: switch (connection) {
            ConnectionPaired(engineUrl: final engineUrl) => _ConnectedView(engineUrl: engineUrl),
            _ => _UnpairedView(onConnect: () => context.push('/settings/connection')),
          },
        ),
      ),
    );
  }
}

class _UnpairedView extends StatelessWidget {
  const _UnpairedView({required this.onConnect});

  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Aún no está conectado a ningún motor.'),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: onConnect,
          child: const Text('Conectar con tu motor'),
        ),
      ],
    );
  }
}

class _ConnectedView extends ConsumerWidget {
  const _ConnectedView({required this.engineUrl});

  final String engineUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reachable = ref.watch(engineReachableProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Conectado a $engineUrl'),
        const SizedBox(height: 8),
        reachable.when(
          data: (ok) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ok ? Icons.check_circle : Icons.error, color: ok ? Colors.green : Colors.red),
              const SizedBox(width: 8),
              Text(ok ? 'Motor accesible' : 'Motor no accesible'),
            ],
          ),
          loading: () => const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          error: (_, _) => const Text('Motor no accesible'),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => context.push('/chat'),
          icon: const Icon(Icons.chat_bubble_outline),
          label: const Text('Hablar con Axi'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/domains'),
          icon: const Icon(Icons.dashboard_outlined),
          label: const Text('Mis datos'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/body'),
          icon: const Icon(Icons.favorite_border),
          label: const Text('¿Cómo está Axi?'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/reminders'),
          icon: const Icon(Icons.notifications_outlined),
          label: const Text('Recordatorios'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/insights'),
          icon: const Icon(Icons.insights_outlined),
          label: const Text('Resumen'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/briefings'),
          icon: const Icon(Icons.campaign_outlined),
          label: const Text('Boletines'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/digest'),
          icon: const Icon(Icons.today_outlined),
          label: const Text('Resumen de hoy'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/graph'),
          icon: const Icon(Icons.hub_outlined),
          label: const Text('Cerebro'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/settings'),
          icon: const Icon(Icons.tune),
          label: const Text('Ajustes'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/meetings'),
          icon: const Icon(Icons.groups_outlined),
          label: const Text('Reuniones'),
        ),
      ],
    );
  }
}
