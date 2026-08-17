// Is the relay actually answering?
//
// NOT "is the VPN up" and NOT "is there a network". Both of those are cheap to
// ask and neither answers the question the sync UI needs: whether an envelope
// posted right now would arrive. A phone can be on excellent Wi-Fi with the
// relay down, and it can be on a captive-portal network that reports itself as
// connected while swallowing every request.
//
// So: ask the relay. `/healthz` is unauthenticated by design — it exists to be
// probed, carries no data, and tells us the one thing we want to know.
import 'package:dio/dio.dart';

/// How long to wait before calling the relay unreachable.
///
/// Short on purpose. This drives a status line, not a transfer: a user opening
/// the sync settings should not stare at a spinner for thirty seconds to be
/// told something is down. A real sync pass uses its own, far longer timeouts.
const Duration kRelayProbeTimeout = Duration(seconds: 5);

class RelayReachability {
  RelayReachability({required this.baseUrl, Dio? dio})
      : _dio = dio ?? Dio();

  final String baseUrl;
  final Dio _dio;

  /// True only when the relay answered 200. Anything else — timeout, DNS
  /// failure, 502, a captive portal returning its own login page — is
  /// unreachable.
  ///
  /// Deliberately does NOT throw. A status probe that can blow up forces every
  /// caller into a try/catch it will eventually forget, and a missed one turns
  /// "the relay is down" into a crash on the settings screen.
  Future<bool> check() async {
    if (baseUrl.isEmpty) return false;
    try {
      final response = await _dio.get<String>(
        '$baseUrl/healthz',
        options: Options(
          responseType: ResponseType.plain,
          sendTimeout: kRelayProbeTimeout,
          receiveTimeout: kRelayProbeTimeout,
          validateStatus: (_) => true,
        ),
      );
      // The body matters as well as the status: a captive portal happily
      // returns 200 with its own HTML, and treating that as "relay up" would
      // leave the user waiting for a sync that can never happen.
      return response.statusCode == 200 &&
          (response.data ?? '').trim() == 'ok';
    } catch (_) {
      return false;
    }
  }
}
