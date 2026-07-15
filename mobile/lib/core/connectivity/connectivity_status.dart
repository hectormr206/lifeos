import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the app is currently talking to the engine successfully (M3
/// slice 1: offline read cache + connectivity awareness).
enum ConnectivityState {
  /// The last request succeeded.
  online,

  /// The last request failed and there was no cached value to fall back to
  /// (or nothing has ever loaded).
  offline,

  /// The last request failed, but a cached value was found and returned —
  /// the UI should show a "showing cached data" banner.
  offlineWithCache,
}

/// App-wide connectivity snapshot. [lastSyncAt] is the timestamp of the
/// data currently on screen: the last successful network fetch, or (while
/// [state] is [ConnectivityState.offlineWithCache]) the cached entry's own
/// `fetchedAt`.
class ConnectivityStatus {
  const ConnectivityStatus({required this.state, this.lastSyncAt});

  final ConnectivityState state;
  final DateTime? lastSyncAt;

  ConnectivityStatus copyWith({ConnectivityState? state, DateTime? lastSyncAt}) => ConnectivityStatus(
        state: state ?? this.state,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      );

  @override
  String toString() => 'ConnectivityStatus(state: $state, lastSyncAt: $lastSyncAt)';
}

/// Minimal reporting surface repositories depend on, so `data/` classes
/// never need to import Riverpod directly — mirrors the app's existing
/// abstract-repository-interface pattern. [ConnectivityNotifier] implements
/// this; a no-op default lets repositories be constructed without wiring
/// connectivity (used by existing repository-level tests).
abstract class ConnectivityReporter {
  void reportOnline();
  void reportOfflineWithCache(DateTime fetchedAt);
  void reportOffline();
}

/// Default [ConnectivityReporter] for repositories built without an explicit
/// one (keeps existing repository constructors/tests working unchanged).
class NoopConnectivityReporter implements ConnectivityReporter {
  const NoopConnectivityReporter();

  @override
  void reportOnline() {}

  @override
  void reportOfflineWithCache(DateTime fetchedAt) {}

  @override
  void reportOffline() {}
}

/// Tracks the app-wide connectivity snapshot, updated by repositories on
/// every request outcome (design decision: one app-wide status rather than
/// per-feature staleness, for least churn — see apply-progress).
class ConnectivityNotifier extends Notifier<ConnectivityStatus> implements ConnectivityReporter {
  @override
  ConnectivityStatus build() => const ConnectivityStatus(state: ConnectivityState.online);

  @override
  void reportOnline() {
    state = ConnectivityStatus(state: ConnectivityState.online, lastSyncAt: DateTime.now());
  }

  @override
  void reportOfflineWithCache(DateTime fetchedAt) {
    state = ConnectivityStatus(state: ConnectivityState.offlineWithCache, lastSyncAt: fetchedAt);
  }

  @override
  void reportOffline() {
    state = state.copyWith(state: ConnectivityState.offline);
  }
}

final connectivityStatusProvider = NotifierProvider<ConnectivityNotifier, ConnectivityStatus>(
  ConnectivityNotifier.new,
);
