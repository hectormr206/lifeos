import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../morning_briefing/data/dio_source_fetcher.dart';
import '../../morning_briefing/domain/source_fetcher.dart';
import '../data/ddg_search_service.dart';
import '../data/web_search_pipeline.dart';

/// The FRESH, unpaired HTTP fetcher used for BOTH the DuckDuckGo request and the
/// result-page fetches (bounded timeouts, plain UA, fail-soft). Reuses the
/// morning-briefing [DioSourceFetcher] so no new `dio` config is introduced.
/// Overridden with a fake in tests.
final webSearchFetcherProvider = Provider<SourceFetcher>((ref) => DioSourceFetcher());

/// The on-device web-search pipeline (DDG-lite → fetch → extract → context +
/// sources). Long-lived; overridden with a fake in tests.
final webSearchPipelineProvider = Provider<WebSearchPipeline>((ref) {
  final fetcher = ref.watch(webSearchFetcherProvider);
  return WebSearchPipeline(
    search: DdgSearchService(fetcher: fetcher),
    fetcher: fetcher,
  );
});
