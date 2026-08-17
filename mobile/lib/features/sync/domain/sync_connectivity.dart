// Whether sync can talk to the relay — which is NOT whether the VPN is up.
//
// THE BUG THIS PREVENTS. `vpn_gate.dart` is the authoritative gate for
// automatic BACKUPS, and it is documented there as explicitly not a general
// connectivity signal. Reusing it for sync would tie a feature that works over
// the open internet to a tunnel it never needed, and a user off the VPN would
// see sync sitting idle with no explanation.
//
// Sync reaches the relay over ordinary HTTPS. The only question that matters is
// whether the relay answered.
library;

/// Why sync is or is not able to run right now.
///
/// An enum rather than a bool because "cannot sync" has three causes with three
/// different remedies, and collapsing them leaves the user staring at a spinner
/// with no idea whether to enable something, connect to Wi-Fi, or wait.
enum SyncConnectivity {
  /// The relay answered. Sync can run.
  reachable,

  /// Sync is switched off. Nothing is wrong; nothing will happen either.
  notEnabled,

  /// Enabled, but the relay did not answer. Offline, or the relay is down.
  unreachable,

  /// Enabled and reachable, but this pass is waiting for Wi-Fi.
  waitingForWifi,
}

extension SyncConnectivityCopy on SyncConnectivity {
  /// What the user reads. Short, and never blames them for something that is
  /// not their doing.
  String get label => switch (this) {
        SyncConnectivity.reachable => 'Sincronización activa',
        SyncConnectivity.notEnabled => 'Sincronización desactivada',
        SyncConnectivity.unreachable => 'Sin conexión con el servidor',
        SyncConnectivity.waitingForWifi => 'Esperando Wi-Fi',
      };

  /// Whether this state is worth interrupting the user about.
  ///
  /// Only `unreachable` is: the other three are either a deliberate choice or a
  /// normal wait. Badging a deliberate choice as a problem teaches people to
  /// ignore badges.
  bool get isProblem => this == SyncConnectivity.unreachable;
}

/// The decision, pure so both the screen and the tests read the same rule.
SyncConnectivity resolveSyncConnectivity({
  required bool syncEnabled,
  required bool relayReachable,
  required bool onUnmeteredNetwork,
}) {
  if (!syncEnabled) return SyncConnectivity.notEnabled;
  if (!relayReachable) return SyncConnectivity.unreachable;
  if (!onUnmeteredNetwork) return SyncConnectivity.waitingForWifi;
  return SyncConnectivity.reachable;
}
