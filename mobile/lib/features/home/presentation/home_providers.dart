import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../connection/domain/connection_status.dart';
import '../../connection/presentation/connection_notifier.dart';
import '../../../core/api/capabilities.dart';

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

/// The paired engine's capability payload, or null when unpaired or
/// unreachable.
///
/// Distinct from [engineReachableProvider], which throws the payload away: some
/// features need to know not just THAT the engine answered but WHAT it can do.
/// Game mode is the first — whether the control exists at all is a property of
/// the engine's hardware, so the app must not guess it.
///
/// Null rather than an error for every failure: a capability that cannot be
/// confirmed is one the UI hides, which is the same handling as "the engine
/// does not have it".
final engineCapabilitiesProvider = FutureProvider<Capabilities?>((ref) async {
  final connection = ref.watch(connectionNotifierProvider);
  if (connection is! ConnectionPaired) return null;
  try {
    return await ref.read(capabilitiesRepositoryProvider).fetch();
  } catch (_) {
    return null;
  }
});
