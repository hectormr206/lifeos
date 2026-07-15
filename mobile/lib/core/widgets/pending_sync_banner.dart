import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../outbox/outbox.dart';

/// Reusable "N pendientes por sincronizar" indicator (M3 slice 2). Renders
/// nothing while the outbox is empty; otherwise shows the current queued
/// mutation count so the user knows their action was saved locally and will
/// replay automatically once connectivity returns (sibling to
/// [OfflineBanner] — drop this at the top of any screen where mutations
/// happen, e.g. the reminders/chat capture bar area).
class PendingSyncBanner extends ConsumerWidget {
  const PendingSyncBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingSyncCountProvider);
    if (count <= 0) {
      return const SizedBox.shrink();
    }

    final label = count == 1 ? '1 pendiente por sincronizar' : '$count pendientes por sincronizar';

    return Material(
      color: Colors.blueGrey.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.sync, size: 18, color: Colors.black54),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, style: const TextStyle(color: Colors.black87, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}
