// Proves MeetingDetailNotifier's lifecycle: loads one meeting's detail on
// init (family keyed by meeting id, mirrors GraphNodeNotifier), error
// surfacing, and refresh. No live engine — repository faked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/meetings/data/meetings_repository.dart';
import 'package:lifeos/features/meetings/domain/meeting.dart';
import 'package:lifeos/features/meetings/domain/meeting_detail.dart';
import 'package:lifeos/features/meetings/presentation/meeting_detail_notifier.dart';
import 'package:lifeos/features/meetings/presentation/meetings_notifier.dart' show meetingsRepositoryProvider;

MeetingDetail _detail(int id, {String summary = 'Resumen de prueba'}) => MeetingDetail(
      id: id,
      start: '2026-07-10 09:00',
      end: '2026-07-10 09:45',
      durationS: 2700,
      status: 'done',
      summary: summary,
      segments: const [],
      speakers: const [],
    );

class _FakeMeetingsRepository implements MeetingsRepository {
  _FakeMeetingsRepository({this.detailValue, this.error});

  MeetingDetail? detailValue;
  final MeetingsException? error;
  int detailCalls = 0;
  int? lastId;

  @override
  Future<List<MeetingModel>> list() => throw UnimplementedError();

  @override
  Future<MeetingDetail> detail(int id) async {
    detailCalls++;
    lastId = id;
    if (error != null) throw error!;
    return detailValue ?? _detail(id);
  }
}

void main() {
  group('MeetingDetailNotifier', () {
    test('loads the meeting detail on init', () async {
      final repo = _FakeMeetingsRepository(detailValue: _detail(12));
      final container = ProviderContainer(overrides: [meetingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(meetingDetailNotifierProvider(12).notifier);
      await notifier.ready;

      final state = container.read(meetingDetailNotifierProvider(12));
      expect(state.loading, isFalse);
      expect(state.detail?.summary, 'Resumen de prueba');
      expect(repo.lastId, 12);
    });

    test('error path surfaces the error message', () async {
      final repo = _FakeMeetingsRepository(error: MeetingsException('boom'));
      final container = ProviderContainer(overrides: [meetingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(meetingDetailNotifierProvider(12).notifier);
      await notifier.ready;

      final state = container.read(meetingDetailNotifierProvider(12));
      expect(state.loading, isFalse);
      expect(state.detail, isNull);
      expect(state.error, 'boom');
    });

    test('refresh reloads the meeting detail', () async {
      final repo = _FakeMeetingsRepository(detailValue: _detail(12));
      final container = ProviderContainer(overrides: [meetingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(meetingDetailNotifierProvider(12).notifier);
      await notifier.ready;
      expect(repo.detailCalls, 1);

      await notifier.refresh();

      expect(repo.detailCalls, 2);
    });

    test('different meeting ids each load independently', () async {
      final repo = _FakeMeetingsRepository();
      final container = ProviderContainer(overrides: [meetingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      await container.read(meetingDetailNotifierProvider(12).notifier).ready;
      await container.read(meetingDetailNotifierProvider(9).notifier).ready;

      expect(container.read(meetingDetailNotifierProvider(12)).detail?.id, 12);
      expect(container.read(meetingDetailNotifierProvider(9)).detail?.id, 9);
    });
  });
}
