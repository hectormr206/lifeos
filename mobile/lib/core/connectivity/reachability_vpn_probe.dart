import 'package:dio/dio.dart';

/// Outcome of one attempt to reach the VPN-only backup-host address.
///
/// Kept distinct from [VpnGateResult] over in `vpn_gate.dart`: this is the
/// raw network signal (did the request succeed, fail clearly, or fail
/// ambiguously?), while `VpnGate` is the layer that assigns MEANING to that
/// signal ("am I on the VPN?"). Separating them lets a future caller reuse
/// the probe for something other than the VPN gate without inheriting gate
/// semantics.
enum ReachabilityOutcome {
  /// The address answered with an HTTP response — ANY status code counts.
  /// This asks "is the tunnel up?", not "is the backup service healthy?": a
  /// 401, a 404, a 500 all prove something answered on the other side. See
  /// [probe]'s doc for why status-based classification is a bug, not a
  /// stricter check.
  reachable,

  /// A clear, unambiguous absence: the connection was refused/unrouted
  /// outright, or the bounded timeout elapsed. Both read the same way on an
  /// unroutable private address like `10.66.66.1` — see design.md's
  /// "off-VPN: immediate network error or the bounded timeout" note.
  unreachable,

  /// Something happened, but not cleanly enough to conclude either way — a
  /// transport-level failure that is neither a clean response nor a
  /// recognized timeout/connection-refused case (bad certificate,
  /// cancellation, dio's generic `unknown` wrapping something unexpected).
  /// Per this repo's silent-failure rule, "I could not tell" must never
  /// collapse into either [reachable] or [unreachable].
  ambiguous,
}

/// Probes the VPN-only backup-host address over HTTP, using the app's
/// existing `dio` — no `connectivity_plus`, no platform channel, nothing
/// Android-specific. This is deliberate (design.md): reachability of the
/// tunnel is the ONLY thing that actually proves the tunnel is up, as
/// opposed to a transport-class signal any commercial VPN would also give.
class ReachabilityVpnProbe {
  ReachabilityVpnProbe({
    required Dio dio,
    this.timeout = const Duration(seconds: 2),
  }) {
    _dio = dio;
  }

  late final Dio _dio;

  /// Bounded so a scheduler firing every few minutes never stalls behind a
  /// hung socket. ~2s: generous for a WireGuard RTT (tens of ms per
  /// design.md's inference — not yet measured on-device, task 2.8), short
  /// enough that "no route" resolves quickly whether it times out or errors
  /// immediately.
  final Duration timeout;

  /// The VPN-only backup-host address (design.md), SAME path
  /// `BackupHostClient` uses for its rung-1 check — there is no
  /// unauthenticated `/health`; only `/v1/health` answers without a key
  /// (confirmed against the real VPS: `/health` -> 401, `/v1/health` -> 200).
  static const String defaultUri = 'http://10.66.66.1:8099/v1/health';

  Future<ReachabilityOutcome> probe({String uri = defaultUri}) async {
    try {
      // `validateStatus` accepts everything so dio never throws on a
      // non-2xx response — status is irrelevant here on purpose: a
      // 401/404/500 still proves the tunnel is up. Narrowing this to
      // "2xx only" would silently couple VPN detection to the backup
      // service's API surface. Do not "tighten" this to 2xx.
      await _dio.getUri<dynamic>(
        Uri.parse(uri),
        options: Options(
          sendTimeout: timeout,
          receiveTimeout: timeout,
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      return ReachabilityOutcome.reachable;
    } on DioException catch (e) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return ReachabilityOutcome.unreachable;
        default:
          // Bad certificate, cancellation, dio's generic `unknown` wrapping
          // an unexpected exception — none of these is the same claim as
          // "I checked, and it is down". Fail loud via `ambiguous` rather
          // than guessing.
          return ReachabilityOutcome.ambiguous;
      }
    }
  }
}
