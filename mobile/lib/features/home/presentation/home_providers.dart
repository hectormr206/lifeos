import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../connection/domain/connection_status.dart';
import '../../connection/presentation/connection_notifier.dart';

/// Whether the paired engine is currently reachable, proven by a live
/// `GET /api/v1/capabilities` call (design D4). Only meaningful once paired;
/// unpaired/pairing/error connection states resolve to `false` without
/// attempting a request.
final engineReachableProvider = FutureProvider.autoDispose<bool>((ref) async {
  final connection = ref.watch(connectionNotifierProvider);
  if (connection is! ConnectionPaired) return false;
  try {
    await ref.read(capabilitiesRepositoryProvider).fetch();
    return true;
  } catch (_) {
    return false;
  }
});
