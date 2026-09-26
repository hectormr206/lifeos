// The goal setting, in memory.
import 'package:lifeos/features/english/data/english_goal_store.dart';
import 'package:lifeos/features/english/domain/english_goal.dart';

class FakeGoalStore implements EnglishGoalStore {
  EnglishGoal? goal;
  final List<EnglishGoal> written = [];

  @override
  Future<EnglishGoal?> read() async => goal;

  @override
  Future<void> write(EnglishGoal value) async {
    goal = value;
    written.add(value);
  }
}
