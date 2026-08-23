import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/chat_day.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';

ChatMessage _msg(String id, DateTime at) => ChatMessage(
      id: id,
      role: ChatRole.user,
      text: id,
      timestamp: at,
    );

void main() {
  // "Now" is a fixed Friday so the weekday bucket is deterministic.
  final now = DateTime(2026, 8, 21, 14, 30); // viernes

  group('chatDayKind', () {
    test('today keeps its own bucket regardless of the hour', () {
      expect(
        chatDayKind(DateTime(2026, 8, 21, 0, 1), now: now),
        ChatDayKind.today,
      );
      expect(
        chatDayKind(DateTime(2026, 8, 21, 23, 59), now: now),
        ChatDayKind.today,
      );
    });

    test('the previous calendar day is yesterday even 30 minutes back', () {
      expect(
        chatDayKind(DateTime(2026, 8, 20, 23, 59), now: now),
        ChatDayKind.yesterday,
      );
    });

    test('two to six days back are named by their weekday', () {
      for (var back = 2; back <= 6; back++) {
        expect(
          chatDayKind(now.subtract(Duration(days: back)), now: now),
          ChatDayKind.weekday,
          reason: '$back days back should read as a weekday name',
        );
      }
    });

    test('a week or more back falls back to the full date', () {
      expect(
        chatDayKind(now.subtract(const Duration(days: 7)), now: now),
        ChatDayKind.fullDate,
      );
      expect(
        chatDayKind(DateTime(2025, 12, 31), now: now),
        ChatDayKind.fullDate,
      );
    });

    test('a timestamp in the future never claims to be today', () {
      expect(
        chatDayKind(DateTime(2026, 8, 22, 9), now: now),
        ChatDayKind.fullDate,
      );
    });
  });

  group('groupMessagesByDay', () {
    test('an empty conversation has no separators', () {
      expect(groupMessagesByDay(const [], now: now), isEmpty);
    });

    test('messages of the same day share one group', () {
      final groups = groupMessagesByDay([
        _msg('a', DateTime(2026, 8, 21, 9)),
        _msg('b', DateTime(2026, 8, 21, 18)),
      ], now: now);

      expect(groups, hasLength(1));
      expect(groups.single.kind, ChatDayKind.today);
      expect(groups.single.messages.map((m) => m.id), ['a', 'b']);
    });

    test('a day change opens a new group and keeps the order', () {
      final groups = groupMessagesByDay([
        _msg('a', DateTime(2026, 8, 19, 9)),
        _msg('b', DateTime(2026, 8, 20, 9)),
        _msg('c', DateTime(2026, 8, 21, 9)),
      ], now: now);

      expect(groups.map((g) => g.kind), [
        ChatDayKind.weekday,
        ChatDayKind.yesterday,
        ChatDayKind.today,
      ]);
      expect(groups.map((g) => g.messages.single.id), ['a', 'b', 'c']);
    });

    test('every group is stamped with the local midnight of its day', () {
      final groups = groupMessagesByDay(
        [_msg('a', DateTime(2026, 8, 21, 23, 59))],
        now: now,
      );
      expect(groups.single.day, DateTime(2026, 8, 21));
    });
  });
}
