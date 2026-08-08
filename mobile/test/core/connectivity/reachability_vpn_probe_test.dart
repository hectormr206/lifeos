// The VPN reachability probe's TIMEOUT CONTRACT.
//
// `vpn_gate_test.dart` covers what the probe DECIDES — reachable, off-VPN,
// unknown — against a fake adapter that answers instantly. That is the right
// shape for classification and the wrong shape for bounding, because an
// adapter which always answers can never exercise the phase that actually
// hangs.
//
// This file exists because of a real omission found in review: the probe set
// `sendTimeout` and `receiveTimeout` but not `connectTimeout`, and the `Dio()`
// injected in `background_tasks.dart` defaults it to null, which dio documents
// as no limit. send/receive only begin counting once a connection EXISTS —
// off the VPN, none ever does. So the "~2 s bounded" probe, described that way
// in three code comments and in design.md, could block through the full SYN
// retransmit: minutes, not seconds. On the automatic-backup path that is a
// background task hanging rather than reporting off-VPN.
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/connectivity/reachability_vpn_probe.dart';

/// Captures the RequestOptions dio actually composed, then answers 200.
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.onRequest);

  final void Function(RequestOptions options) onRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onRequest(options);
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('the probe bounds the CONNECT phase, not only send/receive', () {
    test('connectTimeout reaches the composed request', () async {
      // Asserted on what dio COMPOSED, not on what the probe passed: dio
      // resolves per-request Options against BaseOptions, so composing is the
      // step where a per-request timeout would be silently dropped.
      final dio = Dio();
      RequestOptions? seen;
      dio.httpClientAdapter = _CapturingAdapter((options) => seen = options);

      const timeout = Duration(seconds: 2);
      await ReachabilityVpnProbe(dio: dio, timeout: timeout).probe();

      expect(seen, isNotNull);
      expect(
        seen!.connectTimeout,
        timeout,
        reason: 'without connectTimeout the probe has no bound off-VPN, and '
            'the DioExceptionType.connectionTimeout branch it already handles '
            'can never be reached',
      );
      expect(seen!.sendTimeout, timeout);
      expect(seen!.receiveTimeout, timeout);
    });

    test('a bare injected Dio does not silently remove the bound', () async {
      // background_tasks.dart injects `Dio()` with no BaseOptions. If the
      // probe ever went back to relying on the base config, this fails.
      final dio = Dio(); // deliberately unconfigured, as production injects it
      RequestOptions? seen;
      dio.httpClientAdapter = _CapturingAdapter((options) => seen = options);

      await ReachabilityVpnProbe(dio: dio).probe();

      expect(seen!.connectTimeout, isNotNull);
      expect(seen!.connectTimeout, greaterThan(Duration.zero),
          reason: 'dio treats null and Duration.zero alike: no limit');
    });
  });
}
