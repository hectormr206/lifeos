/// Describes how much TLS trust exists for one engine connection at the
/// moment an HTTP client is built (connection-hardening batch, design
/// D5/D6). Exactly one of [pinnedCaPem] or [trustSelfSigned] is meaningful
/// at a time; when neither is set, default platform certificate validation
/// applies unchanged (e.g. before pairing, or against a real
/// publicly-trusted cert).
class TlsTrustDecision {
  const TlsTrustDecision({this.pinnedCaPem, this.trustSelfSigned = false, this.host});

  /// The pinned CA's PEM text — fetched once from
  /// `GET {engineUrl}/axi-rootCA.crt` at pairing time (design D6), its
  /// fingerprint recorded in `StoredConnection.caFingerprint`. This is the
  /// PREFERRED trust mechanism: standard TLS chain validation against ONLY
  /// this CA via `SecurityContext(withTrustedRoots: false)` — no
  /// certificate-callback bypass involved on the happy path.
  final String? pinnedCaPem;

  /// Dev-only fallback (must be an explicit, visibly-labeled per-connection
  /// toggle in the UI — never silent, never global): accept any certificate
  /// presented by [host], with no pinning check at all.
  final bool trustSelfSigned;

  /// The engine host this decision applies to. Required to scope
  /// [trustSelfSigned] to exactly that host; unused when [pinnedCaPem] is
  /// set (chain validation is inherently host-agnostic once the CA itself
  /// is trusted — same as any normal certificate authority).
  final String? host;

  /// No pin, no fallback — leave the platform default certificate
  /// validation untouched.
  static const none = TlsTrustDecision();

  @override
  bool operator ==(Object other) =>
      other is TlsTrustDecision &&
      other.pinnedCaPem == pinnedCaPem &&
      other.trustSelfSigned == trustSelfSigned &&
      other.host == host;

  @override
  int get hashCode => Object.hash(pinnedCaPem, trustSelfSigned, host);

  @override
  String toString() =>
      'TlsTrustDecision(pinnedCaPem: ${pinnedCaPem != null ? "<${pinnedCaPem!.length} chars>" : null}, '
      'trustSelfSigned: $trustSelfSigned, host: $host)';
}
