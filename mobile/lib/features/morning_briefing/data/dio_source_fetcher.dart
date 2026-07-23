import 'package:dio/dio.dart';

import '../domain/source_fetcher.dart';

/// [SourceFetcher] backed by a FRESH `dio` client (NOT the paired-engine
/// `dioProvider`): news-source URLs are arbitrary public hosts, so this must
/// not inherit the engine base URL, auth headers, or TLS pinning. Bounded
/// timeouts + a plain UA keep it robust; the response is returned as text.
class DioSourceFetcher implements SourceFetcher {
  DioSourceFetcher({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 12),
              // Accept any 2xx/3xx/4xx so we read the body rather than throwing
              // deep in dio; we validate the status ourselves below.
              validateStatus: (status) => status != null && status < 500,
              responseType: ResponseType.plain,
              headers: const {
                'User-Agent': 'LifeOS-Axi/1.0 (morning-briefing)',
                'Accept': 'application/rss+xml, application/atom+xml, text/html, */*',
              },
            ));

  final Dio _dio;

  @override
  Future<String> fetch(String url) async {
    final response = await _dio.get<String>(url);
    final status = response.statusCode ?? 0;
    if (status >= 400) {
      throw Exception('HTTP $status para $url');
    }
    final data = response.data;
    if (data == null || data.isEmpty) {
      throw Exception('Respuesta vacía para $url');
    }
    return data;
  }
}
