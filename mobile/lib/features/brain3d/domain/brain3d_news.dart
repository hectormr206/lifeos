// "Novedades de la semana": what the graph learned lately.
//
// The panel the desktop Cerebro opened on, and the one that answers the
// question a user actually has in front of a graph — not "what is in there"
// but "what did it pick up from me this week".
library;

import 'package:lifeos/core/graph/graph_records.dart';

/// How many items the panel shows. A busy week can add hundreds of rows and a
/// list that long stops being news and becomes a log.
const int kBrain3dNewsLimit = 12;

/// The last seven days of memories, newest first.
///
/// Dated by when the memory HAPPENED, falling back to when it was stored —
/// the same rule the date filter uses, because two panels disagreeing about
/// what "this week" means is worse than either answer.
List<GraphNodeRecord> brain3dWeeklyNews(
  List<GraphNodeRecord> nodes, {
  required DateTime now,
}) {
  final since = now.subtract(const Duration(days: 7));
  // No upper bound: an appointment stored for Friday is precisely what someone
  // wants to see under "this week".
  final recent = [
    for (final n in nodes)
      if ((n.occurredAt ?? n.createdAt).isAfter(since)) n,
  ]..sort((a, b) =>
      (b.occurredAt ?? b.createdAt).compareTo(a.occurredAt ?? a.createdAt));

  return recent.length > kBrain3dNewsLimit
      ? recent.sublist(0, kBrain3dNewsLimit)
      : recent;
}
