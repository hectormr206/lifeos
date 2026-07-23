import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dio_source_fetcher.dart';
import '../data/source_content_extractor.dart';
import '../domain/briefing_notifications.dart';
import '../domain/morning_briefing_preferences.dart';
import '../domain/source_fetcher.dart';

/// Local-only persistence for the on-device briefing (sources + last briefing).
/// Overridden with a fake in tests.
final morningBriefingPreferencesProvider =
    Provider<MorningBriefingPreferences>((ref) => SharedPrefsMorningBriefingPreferences());

/// HTTP fetcher for news sources — a fresh dio client, NOT the paired-engine
/// one. Overridden with a fake in tests so the pipeline never hits the network.
final sourceFetcherProvider = Provider<SourceFetcher>((ref) => DioSourceFetcher());

/// Pure readable-content extractor (feeds → titles+summaries, else stripped
/// HTML). Stateless/pure; a plain provider is enough.
final sourceContentExtractorProvider =
    Provider<SourceContentExtractor>((ref) => const SourceContentExtractor());

/// Local notification poster for "tu boletín está listo" (separate
/// `lifeos_briefing` channel). Overridden with a fake in tests.
final briefingNotificationsProvider =
    Provider<BriefingNotifications>((ref) => FlutterLocalBriefingNotifications());
