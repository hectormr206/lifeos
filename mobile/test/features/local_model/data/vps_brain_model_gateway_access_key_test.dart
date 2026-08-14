// EVERY request to the update host must carry the LifeOS access key — the
// manifest fetch included, not just the weight download.
//
// WHY. The four model paths (`/model/`, `/stt/`, `/tts/`, `/embed/`) were
// served open by nginx while `/manifest` and `/download` were key-gated. Now
// that the host has to be reachable from the public internet (an off-VPN device
// cannot otherwise download anything), those paths get the same gate — so any
// client request that omits the header starts returning 403.
//
// `VpsBrainModelGateway` sends the header on its `DownloadTask`, but its Dio
// was built as `Dio(BaseOptions(baseUrl: ...))` with no default headers, so
// `fetchManifest()` asked for `/manifest.json` bare. Gating the path would have
// made the brain-model update check 403 — and `fetchManifest` swallows
// `DioException` and returns null by design ("offline / nothing published"), so
// the user would see "no update info" forever with nothing in the logs. A
// check that cannot run has to fail loudly; this one would have failed silent.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/update_source_config.dart';
import 'package:lifeos/features/local_model/data/brain_model_source_config.dart';
import 'package:lifeos/features/local_model/data/vps_brain_model_gateway.dart';

/// Captures the headers of the request the gateway actually makes.
class _HeaderSpy extends Interceptor {
  Map<String, dynamic>? seen;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    seen = options.headers;
    handler.reject(
      DioException(requestOptions: options, message: 'stopped before the network'),
      true,
    );
  }
}

void main() {
  test('fetchManifest sends the access key header', () async {
    final spy = _HeaderSpy();
    final dio = Dio(BaseOptions(baseUrl: 'https://updates.example/lifeos/model'))
      ..interceptors.add(spy);

    final gateway = VpsBrainModelGateway(
      config: const BrainModelSourceConfig(baseUrl: 'https://updates.example/lifeos/model'),
      dio: dio,
    );

    await gateway.fetchManifest();

    expect(spy.seen, isNotNull, reason: 'the gateway never issued a request');
    expect(
      spy.seen![kUpdateAccessKeyHeader],
      isNotNull,
      reason: 'the manifest request omits $kUpdateAccessKeyHeader, so it will '
          'be rejected with 403 once /model/ is key-gated — and fetchManifest '
          'turns that into a silent null',
    );
  });

  test('the gateway builds its own Dio with the header when none is injected', () {
    // The injected-Dio path above cannot prove the PRODUCTION construction is
    // right, and production is exactly where no test supplies a Dio:
    // `localModelProviders` calls `VpsBrainModelGateway()` with no arguments.
    final gateway = VpsBrainModelGateway(
      config: const BrainModelSourceConfig(baseUrl: 'https://updates.example/lifeos/model'),
    );

    expect(gateway.debugDefaultHeaders[kUpdateAccessKeyHeader], kUpdateAccessKey);
  });
}
