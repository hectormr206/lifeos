// Practice with the on-device model: role-plays and writing, briefly corrected.
//
// The model is small (Gemma E2B), so everything it is asked is narrow and
// everything it answers is checked:
//   * in a role-play it plays ONE role, in simple English at the learner's
//     level, at most two sentences a turn, and it never corrects mid-talk:
//     being interrupted with grammar is what makes speaking feel like an
//     exam, and anxiety is the thing to beat here;
//   * afterwards it names at most TWO mistakes, the ones that matter most for
//     being understood. Correcting everything teaches nothing;
//   * its feedback must follow a fixed shape. Anything else is "could not
//     review this time", never shown half-parsed.
// Scenarios and writing tasks come from the learner's goal: a client call is
// practice for Héctor, a doctor's appointment for someone learning for daily
// life.
library;

import 'english_goal.dart';
import 'vocab_placement_scoring.dart';

class RoleplayScenario {
  const RoleplayScenario({
    required this.id,
    required this.title,
    required this.role,
    required this.task,
    required this.opening,
  });

  final String id;

  /// Shown to the learner (Spanish).
  final String title;

  /// Who the model plays (English, for the prompt).
  final String role;

  /// What the learner should try to do (Spanish).
  final String task;

  /// The model's first line, so the conversation starts at once.
  final String opening;
}

class WritingTask {
  const WritingTask({
    required this.id,
    required this.title,
    required this.prompt,
  });

  final String id;

  /// Shown to the learner (Spanish).
  final String title;

  /// The task itself, in English: reading it is part of the practice.
  final String prompt;
}

class PracticeTurn {
  const PracticeTurn({required this.fromLearner, required this.text});

  final bool fromLearner;
  final String text;
}

class Correction {
  const Correction({required this.wrong, required this.right, required this.why});

  final String wrong;
  final String right;

  /// A short explanation in Spanish; may be empty.
  final String why;
}

class PracticeFeedback {
  const PracticeFeedback({required this.corrections});

  /// Empty means "no real mistakes", which is an answer, not a failure.
  final List<Correction> corrections;
}

/// Mistakes named per review, at most.
const int kMaxCorrections = 2;

/// Turns of conversation the role-play prompt carries.
const int _recentTurns = 12;

const Map<EnglishGoal, List<RoleplayScenario>> _roleplays = {
  EnglishGoal.work: [
    RoleplayScenario(
      id: 'work.discovery_call',
      title: 'Primera llamada con un cliente',
      role: 'a small business owner in the United States who needs a new '
          'website for their bakery and is talking to a freelance developer '
          'for the first time',
      task: 'Preséntate, pregunta qué necesita y para cuándo lo quiere.',
      opening: 'Hi! Thanks for taking the call. I run a small bakery and our '
          'website is really old.',
    ),
    RoleplayScenario(
      id: 'work.scope_change',
      title: 'El cliente pide algo fuera del alcance',
      role: 'a client in the middle of a project who asks the freelance '
          'developer to add a new feature without changing the price or the '
          'deadline',
      task: 'Explica con amabilidad qué cambia en tiempo y en precio.',
      opening: 'Hey, quick question. Could you also add online payments? It '
          'should be easy, right?',
    ),
    RoleplayScenario(
      id: 'work.standup',
      title: 'Reunión diaria (stand-up)',
      role: 'a project manager running a short daily stand-up meeting with a '
          'remote developer',
      task: 'Cuenta qué hiciste ayer, qué harás hoy y si algo te bloquea.',
      opening: "Good morning! Let's keep it short. What did you work on "
          'yesterday?',
    ),
    RoleplayScenario(
      id: 'work.rate',
      title: 'Defender tu tarifa',
      role: "a startup founder who likes the developer's work but thinks "
          'their hourly rate is too high',
      task: 'Defiende tu tarifa explicando el valor de tu trabajo.',
      opening: 'I really like your portfolio, but your rate is higher than I '
          'expected.',
    ),
  ],
  EnglishGoal.everyday: [
    RoleplayScenario(
      id: 'everyday.restaurant',
      title: 'En un restaurante',
      role: 'a friendly waiter at a restaurant in the United States',
      task: 'Pide una mesa, la comida y la cuenta.',
      opening: 'Hi there! Welcome. How many people?',
    ),
    RoleplayScenario(
      id: 'everyday.doctor',
      title: 'Pedir una cita con el médico',
      role: "a receptionist at a doctor's office answering the phone",
      task: 'Pide una cita para ti y explica qué te pasa.',
      opening: "Good morning, Dr. Miller's office. How can I help you?",
    ),
    RoleplayScenario(
      id: 'everyday.school',
      title: 'Junta con la maestra',
      role: "a teacher at the learner's child's school, at a parent-teacher "
          'meeting',
      task: 'Pregunta cómo va tu hijo y cómo puedes ayudarle.',
      opening: 'Hello, thank you for coming. Please, have a seat.',
    ),
    RoleplayScenario(
      id: 'everyday.neighbor',
      title: 'Conocer a un vecino',
      role: 'a friendly new neighbor who just moved in next door',
      task: 'Preséntate y platica un poco.',
      opening: "Hi! I'm Sam. I just moved in next door.",
    ),
  ],
  EnglishGoal.travel: [
    RoleplayScenario(
      id: 'travel.hotel',
      title: 'Llegar al hotel',
      role: 'a hotel receptionist in London',
      task: 'Haz el check-in y pregunta por el desayuno y el wifi.',
      opening: 'Good evening, welcome to the Riverside Hotel. Do you have a '
          'reservation?',
    ),
    RoleplayScenario(
      id: 'travel.airport',
      title: 'En el mostrador del aeropuerto',
      role: 'an airline agent at the check-in desk of an airport',
      task: 'Documenta tu maleta y pregunta por tu puerta de embarque.',
      opening: 'Hello. Where are you flying today?',
    ),
    RoleplayScenario(
      id: 'travel.directions',
      title: 'Pedir indicaciones',
      role: 'a local person on a street in New York City',
      task: 'Pregunta cómo llegar a un lugar.',
      opening: 'Hi, you look a little lost. Can I help you?',
    ),
  ],
};

const Map<EnglishGoal, List<WritingTask>> _writing = {
  EnglishGoal.work: [
    WritingTask(
      id: 'work.proposal',
      title: 'Propuesta para un cliente',
      prompt: 'Write a short proposal (about five sentences) for a client who '
          'needs a website for their bakery.',
    ),
    WritingTask(
      id: 'work.update',
      title: 'Correo de avance',
      prompt: 'Write an email to a client saying what you finished this week '
          'and what comes next.',
    ),
    WritingTask(
      id: 'work.pull_request',
      title: 'Descripción de un pull request',
      prompt: 'Describe in a few sentences what your code change does and how '
          'to test it.',
    ),
  ],
  EnglishGoal.everyday: [
    WritingTask(
      id: 'everyday.school_email',
      title: 'Correo a la escuela',
      prompt: "Write an email to your child's teacher saying your child will "
          'miss school tomorrow, and why.',
    ),
    WritingTask(
      id: 'everyday.invite',
      title: 'Invitar a una amiga',
      prompt: 'Write a message inviting a friend to dinner this weekend.',
    ),
    WritingTask(
      id: 'everyday.complaint',
      title: 'Una queja amable',
      prompt: 'Write a short message to a store because something you bought '
          'arrived broken.',
    ),
  ],
  EnglishGoal.travel: [
    WritingTask(
      id: 'travel.hotel_email',
      title: 'Correo al hotel',
      prompt: 'Write an email to a hotel asking if you can check in early.',
    ),
    WritingTask(
      id: 'travel.review',
      title: 'Reseña de un lugar',
      prompt: 'Write a short review of a restaurant you visited on a trip.',
    ),
    WritingTask(
      id: 'travel.lost_bag',
      title: 'Maleta perdida',
      prompt: 'Write a message to the airline because your bag did not '
          'arrive.',
    ),
  ],
};

List<RoleplayScenario> roleplaysFor(EnglishGoal goal) => _roleplays[goal]!;

List<WritingTask> writingTasksFor(EnglishGoal goal) => _writing[goal]!;

String buildRoleplayPrompt({
  required RoleplayScenario scenario,
  required CefrLevel level,
  required List<PracticeTurn> turns,
}) {
  final recent = turns.length > _recentTurns
      ? turns.sublist(turns.length - _recentTurns)
      : turns;
  final conversation = [
    for (final t in recent) '${t.fromLearner ? 'Learner' : 'You'}: ${t.text}',
  ].join('\n');
  return 'You are role-playing to help a Spanish speaker practise English.\n'
      'Your role: ${scenario.role}.\n'
      'Speak simple English for a learner at CEFR level '
      '${level.name.toUpperCase()}: common words, short sentences.\n'
      'Reply with at most two sentences, stay in your role, and ask a question '
      'when it helps the conversation go on.\n'
      "Do not correct the learner's English and do not explain grammar; just "
      'answer naturally.\n\n'
      'Conversation so far:\n$conversation\n\n'
      'Write only your next reply.';
}

String buildFeedbackPrompt({required String learnerText}) =>
    'You are an English teacher for a Spanish speaker. Read the learner\'s '
    'English below and find at most two mistakes, the ones that matter most '
    'for being understood (grammar or word choice). Ignore punctuation and '
    'capital letters.\n'
    'For each mistake write exactly three lines:\n'
    "WRONG: the learner's sentence with the mistake\n"
    'RIGHT: the same sentence with EVERY mistake in it corrected\n'
    'WHY: one short explanation, written in Spanish (en español)\n'
    'If there are no real mistakes, write only: NO MISTAKES\n\n'
    "Learner's English:\n$learnerText";

final RegExp _field = RegExp(r'^\s*(WRONG|RIGHT|WHY)\s*:\s*(.*)$');

/// Written English for display: E2B, told to ignore capitals, then writes
/// its own sentences in lowercase ("yesterday i finished"), and a learner
/// must not be shown a lowercase "i" as the correct form. The sentence starts
/// with a capital and the pronoun is "I" (I'm, I've…); "i.e." and words like
/// "iPhone" are left alone.
String _written(String s) {
  final fixed = s.replaceAllMapped(
      RegExp(r"(?<![\w.])i(?=(['’](m|ve|ll|d))?\b)(?![.\w])"), (_) => 'I');
  return fixed.isEmpty ? fixed : fixed[0].toUpperCase() + fixed.substring(1);
}

String _plain(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '').trim();

/// The model's feedback, or null when it did not follow the format.
PracticeFeedback? parseFeedback(String answer) {
  final corrections = <Correction>[];
  String? wrong;
  String? right;
  String why = '';

  // A pair the model repeats is shown once (seen on the Pixel).
  final seen = <String>{};

  void close() {
    if (wrong != null && right != null && _plain(wrong!) != _plain(right!) &&
        seen.add('${_plain(wrong!)}|${_plain(right!)}')) {
      corrections.add(
          Correction(wrong: _written(wrong!), right: _written(right!), why: why));
    }
    wrong = null;
    right = null;
    why = '';
  }

  var sawField = false;
  for (final line in answer.split('\n')) {
    final m = _field.firstMatch(line);
    if (m == null) continue;
    sawField = true;
    final value = m.group(2)!.trim();
    switch (m.group(1)) {
      case 'WRONG':
        close();
        wrong = value;
      case 'RIGHT':
        right = value;
      case 'WHY':
        why = value;
    }
  }
  close();

  if (!sawField) {
    return answer.toUpperCase().contains('NO MISTAKES')
        ? const PracticeFeedback(corrections: [])
        : null;
  }
  return PracticeFeedback(corrections: corrections.take(kMaxCorrections).toList());
}
