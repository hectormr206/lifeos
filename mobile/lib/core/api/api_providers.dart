import 'package:axi_api_client/axi_api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'capabilities_repository.dart';

/// The paired engine's base URL. Foundation placeholder: pairing (design D6,
/// M2) will override this with the address discovered during setup, and
/// attach the device bearer token via a Dio interceptor. Not overridden yet
/// -> requests will simply fail to connect, which is expected pre-pairing.
final engineBaseUrlProvider = Provider<String>((ref) => '');

final dioProvider = Provider<Dio>((ref) {
  return Dio(BaseOptions(baseUrl: ref.watch(engineBaseUrlProvider)));
});

final defaultApiProvider = Provider<DefaultApi>((ref) {
  return DefaultApi(ref.watch(dioProvider));
});

final capabilitiesRepositoryProvider = Provider<CapabilitiesRepository>((ref) {
  return CapabilitiesRepository(ref.watch(defaultApiProvider));
});
