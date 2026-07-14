import 'package:axi_api_client/axi_api_client.dart';
import 'package:dio/dio.dart';

import 'capabilities.dart';

/// Fetches and deserializes `GET /api/v1/capabilities`.
///
/// This is the seam between the generated client ([DefaultApi], produced
/// from `contracts/openapi/axi-v1.json` by `mobile/tool/gen-api.sh`) and the
/// typed [Capabilities] domain model — the "generated client -> engine
/// contract" bind referenced in the mobile-app tasks artifact.
///
/// KNOWN GENERATOR LIMITATION (discovered writing this batch's test): the
/// contract declares this response as `additionalProperties: true` with no
/// fixed properties (FastAPI returns a bare dict — this is intentional per
/// design D4's open, per-capability-versioned shape). openapi-generator's
/// dart-dio `deserialize()` helper only knows how to walk concrete generated
/// model types, `List<T>`/`Set<T>`/`Map<String, T>` of those, and primitives;
/// it cannot walk an arbitrary nested JSON object, so
/// `DefaultApi.capabilitiesApiV1CapabilitiesGet()` throws internally for
/// *any* non-empty response body. It still makes the real HTTP call through
/// the generated path/method, and re-wraps the ORIGINAL, already-decoded
/// response (the untouched raw JSON) into the [DioException] it raises — so
/// we recover the real payload from `error.response!.data` instead of losing
/// it. This is a workaround for the generator's post-processing step only;
/// the request itself is still 100% generated-client-driven. Flagged as a
/// follow-up: giving `/api/v1/capabilities` (and `/api/v1/pair`) declared
/// Pydantic response models on the engine side would let the generator emit
/// real typed models and remove the need for this workaround.
class CapabilitiesRepository {
  const CapabilitiesRepository(this._api);

  final DefaultApi _api;

  Future<Capabilities> fetch() async {
    try {
      final response = await _api.capabilitiesApiV1CapabilitiesGet();
      final body = response.data ?? const <String, Object>{};
      return Capabilities.fromJson(body);
    } on DioException catch (error) {
      final raw = error.response?.data;
      if (raw is Map) {
        return Capabilities.fromJson(Map<String, Object?>.from(raw));
      }
      rethrow;
    }
  }
}
