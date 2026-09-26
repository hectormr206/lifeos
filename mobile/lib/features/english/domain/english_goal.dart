// What the learner wants English FOR.
//
// One installation is one person, so this is a single choice, not a profile.
// It changes WHAT they read and practise (a client call vs. a doctor's
// appointment), never their level, their review or their pace: the placement,
// the core vocabulary and the daily rhythm are the same for everyone. Content
// being about their own life is what the evidence says keeps people going.
library;

/// The synced setting it lives under (see settings/domain/synced_settings).
const String kEnglishGoalSettingKey = 'english.goal';

enum EnglishGoal {
  /// Technology, proposals, calls with clients.
  work,

  /// Shopping, health, school, everyday conversation.
  everyday,

  /// Transport, lodging, places, asking for help.
  travel,
}

/// The stored value back to a goal. An unknown value (a newer version may add
/// goals) is null: guessing what it meant would be worse than asking again.
EnglishGoal? englishGoalFromName(String? name) =>
    EnglishGoal.values.asNameMap()[name];
