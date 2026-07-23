import 'dart:convert';

/// One summarized source inside an on-device morning briefing ("boletín
/// matutino"). Produced by the on-device model from a single configured news
/// source: the human-readable [sourceTitle], the [url] it came from (tappable
/// in the UI), and the model's short [summary].
class BriefingItem {
  const BriefingItem({
    required this.sourceTitle,
    required this.url,
    required this.summary,
  });

  final String sourceTitle;
  final String url;
  final String summary;

  Map<String, dynamic> toJson() => {
        'sourceTitle': sourceTitle,
        'url': url,
        'summary': summary,
      };

  factory BriefingItem.fromJson(Map<String, dynamic> json) => BriefingItem(
        sourceTitle: (json['sourceTitle'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        summary: (json['summary'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is BriefingItem &&
      other.sourceTitle == sourceTitle &&
      other.url == url &&
      other.summary == summary;

  @override
  int get hashCode => Object.hash(sourceTitle, url, summary);
}

/// A briefing generated entirely ON DEVICE by Axi's local model — the phone
/// producing its own "boletín matutino" from the user's configured news
/// sources. Deliberately SEPARATE from [BriefingModel] in features/briefings,
/// which is the pairing-gated viewer mirroring the laptop dashboard: this one
/// never leaves the device.
class OnDeviceBriefing {
  const OnDeviceBriefing({
    required this.intro,
    required this.items,
    required this.generatedAt,
  });

  /// Short overall intro the model writes over the collected summaries.
  final String intro;

  /// One entry per source that was fetched + summarized successfully.
  final List<BriefingItem> items;

  /// When this briefing was produced (local device time).
  final DateTime generatedAt;

  Map<String, dynamic> toJson() => {
        'intro': intro,
        'items': items.map((i) => i.toJson()).toList(),
        'generatedAt': generatedAt.toIso8601String(),
      };

  factory OnDeviceBriefing.fromJson(Map<String, dynamic> json) => OnDeviceBriefing(
        intro: (json['intro'] as String?) ?? '',
        items: ((json['items'] as List<dynamic>?) ?? const [])
            .map((e) => BriefingItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        generatedAt: DateTime.tryParse((json['generatedAt'] as String?) ?? '') ?? DateTime.now(),
      );

  /// Round-trips through [toJson] for shared_preferences string storage.
  String encode() => jsonEncode(toJson());

  /// Rebuilds a briefing from [encode]d text; null on any malformed payload so
  /// a corrupt cache never crashes the screen.
  static OnDeviceBriefing? decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return OnDeviceBriefing.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is OnDeviceBriefing &&
      other.intro == intro &&
      _listEquals(other.items, items) &&
      other.generatedAt == generatedAt;

  @override
  int get hashCode => Object.hash(intro, Object.hashAll(items), generatedAt);
}

bool _listEquals(List<BriefingItem> a, List<BriefingItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
