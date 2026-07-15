import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connectivity/connectivity_status.dart';

/// Reusable "offline / showing cached data" banner (M3 slice 1). Renders
/// nothing unless [connectivityStatusProvider] is
/// [ConnectivityState.offlineWithCache] — the app is unreachable but a
/// repository found a cached value to fall back to. Drop this at the top of
/// any screen's body.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectivityStatusProvider);
    if (status.state != ConnectivityState.offlineWithCache) {
      return const SizedBox.shrink();
    }

    final lastSyncAt = status.lastSyncAt;
    final suffix = lastSyncAt != null ? ' (actualizado ${formatRelativeTime(lastSyncAt)})' : '';

    return Material(
      color: Colors.amber.shade100,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.cloud_off, size: 18, color: Colors.black54),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Sin conexión: mostrando datos guardados$suffix',
                style: const TextStyle(color: Colors.black87, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Formats [time] as a short Spanish relative-time hint (e.g. "justo
/// ahora", "hace 5 min", "hace 2 h", "hace 3 d") for the offline banner.
String formatRelativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inSeconds < 60) return 'justo ahora';
  if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'hace ${diff.inHours} h';
  return 'hace ${diff.inDays} d';
}
