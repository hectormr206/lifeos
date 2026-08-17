// The relay probe answers one question honestly: would an envelope arrive?
//
// The failure this suite is really about is the CAPTIVE PORTAL. A hotel or
// airport network returns 200 with its own login page for every request. A
// probe that only checked the status code would report the relay as up, the
// sync UI would say "activa", and every pass would fail silently while the user
// was told everything was fine.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/sync/data/relay_reachability.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions options) respond;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, __) => respond(options);
}

Dio _dioThat(Future<ResponseBody> Function(RequestOptions) respond) =>
    Dio()..httpClientAdapter = _Adapter(respond);

void main() {
  test('a healthy relay is reachable', () async {
    final probe = RelayReachability(
      baseUrl: 'https://relay.test',
      dio: _dioThat((_) async => ResponseBody.fromString('ok\n', 200)),
    );

    expect(await probe.check(), isTrue);
  });

  test('a captive portal answering 200 with HTML is NOT reachable', () async {
    // The whole reason the body is checked. Status alone would say "up".
    final probe = RelayReachability(
      baseUrl: 'https://relay.test',
      dio: _dioThat((_) async => ResponseBody.fromString(
            '<html><body>Inicia sesión para usar el Wi-Fi</body></html>',
            200,
          )),
    );

    expect(await probe.check(), isFalse);
  });

  test('a 502 is not reachable', () async {
    final probe = RelayReachability(
      baseUrl: 'https://relay.test',
      dio: _dioThat((_) async => ResponseBody.fromString('bad gateway', 502)),
    );

    expect(await probe.check(), isFalse);
  });

  test('a network error is reported, never thrown', () async {
    // A status probe that can blow up forces every caller into a try/catch it
    // will eventually forget, and a missed one turns "the relay is down" into
    // a crash on the settings screen.
    final probe = RelayReachability(
      baseUrl: 'https://relay.test',
      dio: _dioThat((options) async =>
          throw DioException(requestOptions: options, message: 'no route')),
    );

    expect(await probe.check(), isFalse);
  });

  test('an unconfigured relay is unreachable without a request', () async {
    var called = false;
    final probe = RelayReachability(
      baseUrl: '',
      dio: _dioThat((_) async {
        called = true;
        return ResponseBody.fromString('ok\n', 200);
      }),
    );

    expect(await probe.check(), isFalse);
    expect(called, isFalse,
        reason: 'an empty base URL must not produce a request to nowhere');
  });

  test('it probes /healthz, which needs no key and carries no data', () async {
    String? path;
    final probe = RelayReachability(
      baseUrl: 'https://relay.test',
      dio: _dioThat((options) async {
        path = options.path;
        return ResponseBody.fromString('ok\n', 200);
      }),
    );

    await probe.check();

    expect(path, 'https://relay.test/healthz');
  });
}
