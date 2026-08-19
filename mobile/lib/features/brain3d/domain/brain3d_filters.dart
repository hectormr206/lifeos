// Search, domain and date — the controls the desktop Cerebro has always had.
//
// A graph of 88 nodes and 277 relationships is not navigable by orbiting it.
// The original answers that with a search box, a domain list and four date
// chips, and that is the difference between a picture and a tool.
//
// Pure functions over already-loaded nodes: filtering must never re-query the
// store, or every keystroke becomes a database round trip on the phone.
library;

import 'package:lifeos/core/graph/graph_records.dart';

/// The date windows the original offers, in its order.
enum Brain3dDateRange { all, today, week, month }

class Brain3dFilter {
  const Brain3dFilter({
    this.query = '',
    this.domain,
    this.range = Brain3dDateRange.all,
  });

  final String query;

  /// Null means "Todos".
  final String? domain;

  final Brain3dDateRange range;

  Brain3dFilter copyWith({
    String? query,
    String? domain,
    bool clearDomain = false,
    Brain3dDateRange? range,
  }) =>
      Brain3dFilter(
        query: query ?? this.query,
        domain: clearDomain ? null : (domain ?? this.domain),
        range: range ?? this.range,
      );

  bool get isActive =>
      query.trim().isNotEmpty || domain != null || range != Brain3dDateRange.all;
}

/// Start of the window [range] covers, or null for "everything".
///
/// Day-based, not 24-hour: "hoy" means today, so something logged at 00:30 is
/// still today at 23:00 rather than dropping out after a day has passed.
DateTime? brain3dRangeStart(Brain3dDateRange range, DateTime now) =>
    switch (range) {
      Brain3dDateRange.all => null,
      Brain3dDateRange.today => DateTime(now.year, now.month, now.day),
      Brain3dDateRange.week =>
        DateTime(now.year, now.month, now.day).subtract(const Duration(days: 7)),
      Brain3dDateRange.month =>
        DateTime(now.year, now.month, now.day).subtract(const Duration(days: 30)),
    };

/// The nodes a filter keeps.
///
/// Matching is accent- and case-insensitive on the LABEL: people search for
/// "presion" having written "presión", and a search that fails on an accent
/// teaches them the box does not work.
List<GraphNodeRecord> applyBrain3dFilter(
  List<GraphNodeRecord> nodes,
  Brain3dFilter filter, {
  required DateTime now,
}) {
  final needle = _fold(filter.query.trim());
  final start = brain3dRangeStart(filter.range, now);

  return [
    for (final n in nodes)
      if ((needle.isEmpty || _fold(n.label).contains(needle)) &&
          (filter.domain == null || n.domain == filter.domain) &&
          (start == null || !_dateOf(n).isBefore(start)))
        n,
  ];
}

/// The date a memory is filtered by: when it HAPPENED if that is known, else
/// when it was written. A blood pressure taken yesterday and logged today
/// belongs to yesterday.
DateTime _dateOf(GraphNodeRecord n) => n.occurredAt ?? n.createdAt;

String _fold(String s) {
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ';
  const to = 'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC';
  final buffer = StringBuffer();
  for (final rune in s.toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    final i = from.indexOf(ch);
    buffer.write(i >= 0 ? to[i].toLowerCase() : ch);
  }
  return buffer.toString();
}
