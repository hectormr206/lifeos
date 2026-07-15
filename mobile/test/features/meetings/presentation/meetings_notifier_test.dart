// Proves MeetingsNotifier's lifecycle: loads the meetings list on init,
// error surfacing, and refresh. No live engine — repository faked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/meetings/data/meetings_repository.dart';
import 'package:lifeos/features/meetings/domain/meeting.dart';
import 'package:lifeos/features/meetings/domain/meeting_detail.dart';
import 'package:lifeos/features/meetings/presentation/meetings_notifier.dart';

class _FakeMeetingsRepository implements MeetingsRepository {
  _FakeMeetingsRepository({this.meetings = const [], this.error});

  List<MeetingModel> meetings;
  final MeetingsException? error;
  int listCalls = 0;

  @override
  Future<List<MeetingModel>> list() async {
    listCalls++;
    if (error != null) throw error!;
    return meetings;
  }

  @override
  Future<MeetingDetail> detail(int id) => throw UnimplementedError();
}

void main() {
  group('MeetingsNotifier', () {
    test('loads the meetings list on init', () async {
      final meeting = MeetingModel(
        id: 12,
        start: '2026-07-10 09:00',
        startTs: DateTime.utc(2026, 7, 10, 9),
        end: '2026-07-10 09:45',
        durationS: 2700,
        status: 'done',
        source: 'auto',
        hasTranscript: true,
        hasSummary: true,
      );
      final repo = _FakeMeetingsRepository(meetings: [meeting]);
      final container = ProviderContainer(overrides: [meetingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(meetingsNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(meetingsNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.meetings, [meeting]);
      expect(repo.listCalls, 1);
    });

    test('error path surfaces the error message', () async {
      final repo = _FakeMeetingsRepository(error: MeetingsException('boom'));
      final container = ProviderContainer(overrides: [meetingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(meetingsNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(meetingsNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.meetings, isEmpty);
      expect(state.error, 'boom');
    });

    test('refresh reloads the meetings list', () async {
      final repo = _FakeMeetingsRepository();
      final container = ProviderContainer(overrides: [meetingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(meetingsNotifierProvider.notifier);
      await notifier.ready;
      expect(repo.listCalls, 1);

      await notifier.refresh();

      expect(repo.listCalls, 2);
    });
  });
}
