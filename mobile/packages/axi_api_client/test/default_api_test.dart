import 'package:test/test.dart';
import 'package:axi_api_client/axi_api_client.dart';


/// tests for DefaultApi
void main() {
  final instance = AxiApiClient().getDefaultApi();

  group(DefaultApi, () {
    // Capabilities
    //
    // Capability negotiation payload (design D4).  Auth: this route is a normal `/api/v1/_*` endpoint — NOT in `axi.api_auth.PUBLIC_V1_PATHS` — so it is subject to the same strict bearer-auth rule as every other v1 route once `api_auth_enabled=true`.
    //
    //Future<Map<String, Object>> capabilitiesApiV1CapabilitiesGet() async
    test('test capabilitiesApiV1CapabilitiesGet', () async {
      // TODO
    });

    // Pair
    //
    // Exchange a valid, unexpired, unused pairing code for a device token.  Auth: this route is in `axi.api_auth.PUBLIC_V1_PATHS` — reachable with no bearer token even when `api_auth_enabled=true` (it is the mechanism that BOOTSTRAPS a device's first token). The pairing code itself is the security boundary: it can only be obtained from `/setup`'s `GET /api/setup/pairing_code`, an owner-facing legacy route (spec `api-auth-pairing`), is single-use, and expires after 5 minutes (`axi.pairing`, design D6).  Raises 410 if the code is missing/unknown/expired/already-used — no device is created and no token is issued in that case (spec: \"Expired code rejected\").
    //
    //Future<Map<String, Object>> pairApiV1PairPost(PairRequest pairRequest) async
    test('test pairApiV1PairPost', () async {
      // TODO
    });

  });
}
