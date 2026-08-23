import 'package:flutter/foundation.dart';

import 'chat_message.dart';

/// How a day separator should name its day in the message list (WhatsApp-style
/// grouping): the two nearest days get a word, the rest of the week gets its
/// weekday name, and anything older gets an explicit date.
///
/// The *rendering* of each kind belongs to the presentation layer — this
/// domain only decides WHICH kind a timestamp falls into, so the rule stays
/// testable without a widget tree or a locale.
enum ChatDayKind { today, yesterday, weekday, fullDate }

/// One run of consecutive messages that happened on the same calendar day,
/// with the separator that introduces it.
@immutable
class ChatDayGroup {
  const ChatDayGroup({
    required this.day,
    required this.kind,
    required this.messages,
  });

  /// Local midnight of the day this group belongs to — the value the
  /// presentation formats when [kind] is [ChatDayKind.fullDate].
  final DateTime day;
  final ChatDayKind kind;
  final List<ChatMessage> messages;
}

/// Local midnight of [t], i.e. the calendar day it belongs to.
DateTime chatDayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// Whether [a] and [b] fall on the same calendar day (local time).
bool isSameChatDay(DateTime a, DateTime b) => chatDayOf(a) == chatDayOf(b);

/// Which separator names the day of [when], relative to [now].
///
/// Calendar days, not elapsed hours: a message from 23:59 yesterday is
/// "ayer" even though it is 30 minutes old. A timestamp in the future (clock
/// skew, or a device whose date is wrong) falls back to the explicit date
/// rather than lying with "hoy".
ChatDayKind chatDayKind(DateTime when, {required DateTime now}) {
  final days = chatDayOf(now).difference(chatDayOf(when)).inDays;
  return switch (days) {
    0 => ChatDayKind.today,
    1 => ChatDayKind.yesterday,
    >= 2 && <= 6 => ChatDayKind.weekday,
    _ => ChatDayKind.fullDate,
  };
}

/// Splits [messages] — in display order — into consecutive same-day groups.
///
/// The order is preserved exactly as given: a group opens whenever the day
/// changes, so the list never reorders what the user is reading.
List<ChatDayGroup> groupMessagesByDay(
  List<ChatMessage> messages, {
  required DateTime now,
}) {
  final groups = <ChatDayGroup>[];
  for (final message in messages) {
    final day = chatDayOf(message.timestamp);
    if (groups.isNotEmpty && groups.last.day == day) {
      groups.last.messages.add(message);
      continue;
    }
    groups.add(
      ChatDayGroup(
        day: day,
        kind: chatDayKind(message.timestamp, now: now),
        messages: [message],
      ),
    );
  }
  return groups;
}
