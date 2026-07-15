import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/chat/presentation/chat_screen.dart';
import 'features/connection/domain/connection_status.dart';
import 'features/connection/presentation/connection_notifier.dart';
import 'features/connection/presentation/connection_screen.dart';
import 'features/domains/domain/domain_descriptor.dart';
import 'features/domains/presentation/domain_list_screen.dart';
import 'features/domains/presentation/domains_hub_screen.dart';
import 'features/home/presentation/home_screen.dart';

/// App shell routing (M1 slice 1). Design D1 did not pin a router package;
/// `go_router` is the de-facto Flutter-recommended choice and is what this
/// slice adds (documented in apply-progress, M1-slice-1 section).
///
/// M1 slice 2: `/chat` is gated behind pairing (spec mobile-app-shell) — an
/// unpaired device is redirected to `/settings/connection` instead of
/// reaching the chat screen.
///
/// M2 slice 1: `/domains` (hub) and `/domains/:key` (per-domain list, spec
/// `mobile-domain-crud`) are gated behind pairing the same way.
final goRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final needsPairing = loc == '/chat' || loc.startsWith('/domains');
      if (needsPairing && ref.read(connectionNotifierProvider) is! ConnectionPaired) {
        return '/settings/connection';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
      GoRoute(path: '/settings/connection', builder: (context, state) => const ConnectionScreen()),
      GoRoute(path: '/chat', builder: (context, state) => const ChatScreen()),
      GoRoute(path: '/domains', builder: (context, state) => const DomainsHubScreen()),
      GoRoute(
        path: '/domains/:key',
        builder: (context, state) => DomainListScreen(descriptor: domainDescriptorFor(state.pathParameters['key']!)),
      ),
    ],
  );
});

/// Root widget (design D1 foundation). Wrapped in a [ProviderScope] by
/// [main] — this widget itself stays framework-agnostic so widget tests can
/// pump it directly inside their own [ProviderScope].
class LifeOSApp extends ConsumerWidget {
  const LifeOSApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(goRouterProvider);
    return MaterialApp.router(
      title: 'LifeOS',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      routerConfig: router,
    );
  }
}
