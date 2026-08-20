/// Seam for fetching the raw bytes of a news source over HTTP. Abstract so the
/// pipeline is unit-testable with a fake (no network) and the concrete
/// `dio`-backed implementation ([DioSourceFetcher]) stays at the edge.
abstract class SourceFetcher {
  /// GETs [url] and returns the response body as text. Implementations MUST
  /// throw on any transport/status failure so the pipeline can skip that one
  /// source (per-source try/catch) instead of failing the whole briefing.
  /// [headers] carries per-request auth — the private SearXNG behind a key.
  /// Optional so every existing caller and fake keeps working untouched.
  Future<String> fetch(String url, {Map<String, String>? headers});
}
