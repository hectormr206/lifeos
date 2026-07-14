# axi_api_client.api.DefaultApi

## Load the API package
```dart
import 'package:axi_api_client/api.dart';
```

All URIs are relative to *http://localhost*

Method | HTTP request | Description
------------- | ------------- | -------------
[**capabilitiesApiV1CapabilitiesGet**](DefaultApi.md#capabilitiesapiv1capabilitiesget) | **GET** /api/v1/capabilities | Capabilities
[**pairApiV1PairPost**](DefaultApi.md#pairapiv1pairpost) | **POST** /api/v1/pair | Pair


# **capabilitiesApiV1CapabilitiesGet**
> Map<String, Object> capabilitiesApiV1CapabilitiesGet()

Capabilities

Capability negotiation payload (design D4).  Auth: this route is a normal `/api/v1/_*` endpoint — NOT in `axi.api_auth.PUBLIC_V1_PATHS` — so it is subject to the same strict bearer-auth rule as every other v1 route once `api_auth_enabled=true`.

### Example
```dart
import 'package:axi_api_client/api.dart';

final api = AxiApiClient().getDefaultApi();

try {
    final response = api.capabilitiesApiV1CapabilitiesGet();
    print(response);
} on DioException catch (e) {
    print('Exception when calling DefaultApi->capabilitiesApiV1CapabilitiesGet: $e\n');
}
```

### Parameters
This endpoint does not need any parameter.

### Return type

**Map&lt;String, Object&gt;**

### Authorization

No authorization required

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **pairApiV1PairPost**
> Map<String, Object> pairApiV1PairPost(pairRequest)

Pair

Exchange a valid, unexpired, unused pairing code for a device token.  Auth: this route is in `axi.api_auth.PUBLIC_V1_PATHS` — reachable with no bearer token even when `api_auth_enabled=true` (it is the mechanism that BOOTSTRAPS a device's first token). The pairing code itself is the security boundary: it can only be obtained from `/setup`'s `GET /api/setup/pairing_code`, an owner-facing legacy route (spec `api-auth-pairing`), is single-use, and expires after 5 minutes (`axi.pairing`, design D6).  Raises 410 if the code is missing/unknown/expired/already-used — no device is created and no token is issued in that case (spec: \"Expired code rejected\").

### Example
```dart
import 'package:axi_api_client/api.dart';

final api = AxiApiClient().getDefaultApi();
final PairRequest pairRequest = ; // PairRequest | 

try {
    final response = api.pairApiV1PairPost(pairRequest);
    print(response);
} on DioException catch (e) {
    print('Exception when calling DefaultApi->pairApiV1PairPost: $e\n');
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **pairRequest** | [**PairRequest**](PairRequest.md)|  | 

### Return type

**Map&lt;String, Object&gt;**

### Authorization

No authorization required

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

