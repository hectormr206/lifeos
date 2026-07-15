import 'package:dio/dio.dart';

import '../auth/token_store.dart';

/// Injects `Authorization: Bearer <token>` (design D5) from the persisted
/// [TokenStore] on every outgoing request, once the device is paired.
/// Silent no-op pre-pairing (no header added): `POST /api/v1/pair` is a
/// public v1 route (design D6) and every other v1 route correctly 401s
/// until the device pairs.
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this._tokenStore);

  final TokenStore _tokenStore;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    final stored = await _tokenStore.load();
    if (stored != null) {
      options.headers['Authorization'] = 'Bearer ${stored.token}';
    }
    handler.next(options);
  }
}
