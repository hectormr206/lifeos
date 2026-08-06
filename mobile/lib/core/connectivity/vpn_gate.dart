import 'reachability_vpn_probe.dart';

/// Whether this device can currently reach the VPN-only backup-host address.
///
/// THREE states, not two, and that is the entire point: "I could not tell"
/// ([unknown]) is not the same claim as "I checked, and it is down"
/// ([offVpn]). A scheduler (Phase 3) that skips a backup on [offVpn] treats
/// it as an ordinary, expected wait — same as waiting for Wi-Fi. [unknown]
/// must be surfaced loudly instead, per this repo's fail-loudly rule: a
/// check that could not run is not the same as a check that ran and passed.
/// [unknown] must NEVER be treated as [onVpn] by any caller.
enum VpnGateResult { onVpn, offVpn, unknown }

/// Answers "am I on the VPN to MY VPS?" — the sole authoritative gate for
/// automatic backups (design.md, specs/vpn-gated-backups/spec.md).
/// Deliberately does NOT consult `NetworkCapabilities.TRANSPORT_VPN` or any
/// other platform-specific signal: that API identifies a transport CLASS
/// (any VPN at all, including an unrelated commercial one someone else is
/// running), not OUR tunnel's identity. Reachability of the VPN-only address
/// is the only signal that actually distinguishes the two.
///
/// IMPORTANT — this is an ATTEMPT gate, not an authentication mechanism. A
/// hostile device on the same LAN segment as `10.66.66.1` could, in
/// principle, answer at that address and make this gate report [onVpn].
/// That is an accepted, bounded risk: whatever gets sent afterward is
/// sealed client-side (the backup-host never decrypts it), and the actual
/// defence against talking to an impostor is server-identity validation at
/// the TLS layer (`mobile/lib/core/tls/tls_adapter_factory.dart` +
/// `tls_trust_decision.dart`), which a caller wiring up the real upload
/// path (Phase 3) MUST apply before sending anything. This gate only
/// decides whether to ATTEMPT — see `vpn_gate_test.dart`'s hostile-LAN
/// group for the explicit boundary and the TLS layer it hands off to.
///
/// Takes the operating-system NAME as a constructor parameter rather than
/// reading `Platform` inline — the same seam `core/platform/app_platform.dart`
/// uses, for the same reason: it lets the Linux-hosted widget/unit suite
/// assert Android behaviour with no real device. Every OS takes the
/// identical reachability-only path today; task 2.7's optional
/// `TRANSPORT_VPN` pre-check is a non-blocking, implementation-time spike
/// explicitly out of scope for this PR. The parameter exists now so that
/// spike has a seam to attach to later without changing this class's public
/// shape.
class VpnGate {
  VpnGate({required ReachabilityVpnProbe probe, required this.operatingSystem}) {
    _probe = probe;
  }

  late final ReachabilityVpnProbe _probe;

  /// The OS this gate was built for. See class doc — currently informational
  /// only (every OS behaves identically), reserved for task 2.7.
  final String operatingSystem;

  Future<VpnGateResult> check() async {
    final outcome = await _probe.probe();
    return switch (outcome) {
      ReachabilityOutcome.reachable => VpnGateResult.onVpn,
      ReachabilityOutcome.unreachable => VpnGateResult.offVpn,
      ReachabilityOutcome.ambiguous => VpnGateResult.unknown,
    };
  }
}
