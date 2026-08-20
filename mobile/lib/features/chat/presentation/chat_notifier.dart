import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/clock/clock.dart';
import '../../../core/graph/graph_providers.dart';
import '../../../core/outbox/outbox.dart';
import '../../../l10n/app_localizations.dart';
import '../../../l10n/locale_providers.dart';
import '../../domains/domain/domain_descriptor.dart';
import '../../local_model/data/on_device_chat_repository.dart';
import '../../memory/domain/user_naming.dart';
import '../../reminders/domain/local_reminder.dart';
import '../../reminders/domain/reminder_parser.dart';
import '../../reminders/presentation/local_reminders_providers.dart';
import '../../local_model/presentation/local_model_providers.dart';
import '../../stt/presentation/stt_providers.dart';
import '../../web_search/data/search_augmented_chat_repository.dart';
import '../../web_search/domain/web_search_settings.dart';
import '../../web_search/presentation/web_search_providers.dart';
import '../data/chat_history_repository.dart';
import '../data/chat_repository.dart';
import '../domain/chat_context_builder.dart';
import '../domain/conversation_subject.dart';
import '../domain/correction.dart';
import '../domain/opening_line.dart';
import '../domain/person_answer.dart';
import '../../memory/domain/when_answer.dart';
import '../domain/person_facts.dart';
import '../domain/acknowledgement.dart';
import '../domain/chat_message.dart';
import '../domain/reply_quality.dart';
import 'chat_context_providers.dart';
import 'chat_providers.dart';

/// The [ChatRepository] used app-wide; overridden with a fake in tests.
///
/// Roadmap SLICE 1: when the on-device toggle ([localModelEnabledProvider]) is
/// ON, chat is served entirely on-device by [OnDeviceChatRepository]; otherwise
/// the normal [HttpChatRepository] talks to the paired engine (wired with the
/// offline write outbox + pending-sync reporter, M3 slice 2). Flipping the
/// toggle rebuilds this provider, so the active chat screen swaps backends live.
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final ChatRepository base;
  if (ref.watch(localModelEnabledProvider)) {
    // SLICE C1: every on-device turn is prefixed with the full Axi context —
    // (a) Axi's persona + response guidance, (b) a relevant MEMORY block routed
    // + recalled from the graph, and (c) the reply-language + device-local
    // date/time lines. Built async by the shared `chatContextBuilderProvider`
    // (it recalls memory and disposes the embedder before the LLM loads).
    // `read` (not `watch`) so a language/clock change never rebuilds the
    // repository (which would drop the loaded weights / FIFO lock) — the builder
    // re-reads language + clock live at each send.
    base = OnDeviceChatRepository(
      ref.watch(localLlmEngineProvider),
      decoratePrompt: (message) =>
          ref.read(chatContextBuilderProvider).buildPreamble(message),
    );
  } else {
    base = HttpChatRepository(
      ref.watch(dioProvider),
      outbox: ref.watch(outboxProvider),
      pendingSync: ref.watch(pendingSyncCountProvider.notifier),
    );
  }
  // Roadmap slice B4: when "buscar en internet" is on, wrap the active backend
  // in the web-search decorator (grounds each text turn in live DDG results and
  // appends a sources list). Rebuilding on toggle only re-creates the light
  // wrapper — the long-lived on-device engine (its own provider) is untouched,
  // so no weights reload. `read` for the sources label so a language change is
  // honoured at send-time without rebuilding.
  // The user-selected provider can disable search entirely: when it is
  // `none`, the augmentation is skipped regardless of a stale-enabled toggle
  // (the globe button is also hidden + forced off upstream), so no outbound
  // search request is ever made.
  final searchProvider = ref.watch(webSearchSettingsProvider).provider;
  if (searchProvider != WebSearchProvider.none && ref.watch(webSearchEnabledProvider)) {
    return SearchAugmentedChatRepository(
      inner: base,
      pipeline: ref.watch(webSearchPipelineProvider),
      sourcesLabel: () => ref.read(appLanguageCodeProvider) == 'en' ? 'Sources' : 'Fuentes',
    );
  }
  return base;
});

/// On-device persistence of chat history via the local graph store (SLICE A2).
///
/// Async because the underlying [localGraphStoreProvider] opens/keys the
/// encrypted DB lazily. Consumers `await ...future` and DEGRADE GRACEFULLY on
/// failure (store not ready / unavailable) — the chat stays fully usable
/// in-memory, it just won't survive a restart. Overridden with a fake (or an
/// in-memory sqflite store) in tests.
final chatHistoryRepositoryProvider = FutureProvider<ChatHistoryRepository>((ref) async {
  final store = await ref.watch(localGraphStoreProvider.future);
  return ChatHistoryRepository(store);
});

/// The chat conversation's UI state (spec mobile-chat).
class ChatUiState {
  const ChatUiState({
    this.messages = const [],
    this.sending = false,
    this.error,
    this.hydrating = true,
  });

  final List<ChatMessage> messages;
  final bool sending;
  final String? error;

  /// True until the persisted transcript has been read (or given up on).
  ///
  /// Without it, an empty conversation caused by a store that is still opening
  /// looks EXACTLY like a conversation with no messages — and the user cannot
  /// tell those apart. One of them is frightening in an app that holds your
  /// life, and the only feedback they got was force-closing the app.
  final bool hydrating;

  ChatUiState copyWith({
    List<ChatMessage>? messages,
    bool? sending,
    String? error,
    bool? hydrating,
  }) =>
      ChatUiState(
        messages: messages ?? this.messages,
        sending: sending ?? this.sending,
        error: error,
        hydrating: hydrating ?? this.hydrating,
      );
}

final chatNotifierProvider = NotifierProvider<ChatNotifier, ChatUiState>(ChatNotifier.new);

/// Manages the chat conversation's lifecycle (spec mobile-chat, M1 slice 2):
/// loads history on init, sends messages with an optimistic user-message
/// append, and surfaces send failures without losing the typed message or
/// inventing a phantom Axi reply.
class ChatNotifier extends Notifier<ChatUiState> {
  Future<void>? _bootstrapFuture;

  /// FIFO queue of outgoing generations (text + image turns). Every send is
  /// enqueued and a SINGLE [_drain] loop processes them one at a time, awaiting
  /// each repository call fully before starting the next. This is the safety
  /// invariant: the on-device flutter_gemma session is single-threaded, so two
  /// concurrent generations would corrupt it. The keyboard `onSubmitted` path,
  /// the send button, and rapid taps ALL funnel through here, so a second send
  /// can never start a concurrent model call — it just waits its turn. Axi
  /// answers each in the order they were fired.
  final Queue<_OutgoingRequest> _queue = Queue<_OutgoingRequest>();
  bool _draining = false;

  /// Who the conversation is about right now, and the people already stored.
  /// Both live on the notifier because a subject that reset with the widget
  /// would lose the thread every time the screen rebuilt.
  ConversationSubject? _subject;
  List<String> _knownPeople = const [];

  /// Set once the provider is disposed (chat screen closed, on-device toggle
  /// flipped). The [_drain] loop and [_loadHistory] check this after every
  /// `await` and bail WITHOUT touching `state` — mutating a disposed Notifier
  /// throws, and because the drain runs unawaited that error would escape as an
  /// uncaught async failure (the resource leak this guards against).
  bool _disposed = false;

  /// Stable id of the seeded first-run greeting (Axi's onboarding name
  /// question). Persisted with the message, so its presence as the LAST bubble
  /// is what tells a bare reply ("Héctor") that it is the user's name — even
  /// across an app restart (the id survives serialization).
  static const String onboardingQuestionId = 'onboarding-name-question';

  /// True once the user's own name is known (captured or already on the hub).
  /// While false, each send attempts a deterministic name capture; once true
  /// the onboarding path is skipped entirely so it never touches normal chat.
  bool _userNameKnown = false;

  /// Lets tests await the initial [loadHistory] deterministically, mirroring
  /// `ConnectionNotifier.ready`.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  /// Completes when the persisted transcript has been loaded or abandoned.
  /// Separate from [ready] because hydration is deliberately detached: a slow
  /// store must never block the chat from being usable.
  Future<void> get hydrationSettled =>
      _persistedHydration ?? Future<void>.value();

  @override
  ChatUiState build() {
    ref.onDispose(_handleDispose);
    _bootstrapFuture = _loadHistory().then((_) => _maybeOpenWithSomething());
    _loadKnownPeople();
    return const ChatUiState();
  }

  /// The people already in the graph, so a name typed mid-conversation is
  /// recognised as a PERSON rather than as one more capitalised word — the
  /// difference between "Juan vive en Puebla" staying about Juan and the
  /// conversation quietly switching to a city.
  ///
  /// Best-effort: a chat that cannot read the store still works, it just
  /// tracks the thread less confidently.
  void _loadKnownPeople() {
    // Reads the store only if it is ALREADY open — never awaits the future
    // that opens it. Awaiting it blocked the chat's bootstrap, and in a test
    // with no store override that future never resolves at all, so every chat
    // test hung. Timing out instead left a pending Timer, which the test
    // binding rightly refuses.
    //
    // Missing the list only makes the subject logic less confident, never
    // wrong, and the next turn tries again.
    final store = ref.read(localGraphStoreProvider).value;
    if (store == null) return;
    store.listNodesByKind('person').then((people) {
      if (_disposed) return;
      _knownPeople = [
        for (final p in people)
          if (p.label.trim().isNotEmpty) p.label.trim(),
      ];
    }).catchError((_) {});
  }

  /// Tears the queue down deterministically when the provider is disposed.
  /// Anything still queued or in flight must never resolve against a disposed
  /// notifier, so we mark [_disposed] (the drain bails after its next await) and
  /// complete every pending request's [_OutgoingRequest.done] so callers still
  /// awaiting a send unwind instead of hanging forever.
  void _handleDispose() {
    _disposed = true;
    // Cancel the retry pause AND release whoever is awaiting it, or the
    // hydration loop would wait for a timer that will never fire.
    _hydrationTimer?.cancel();
    _hydrationTimer = null;
    final waiter = _hydrationWait;
    _hydrationWait = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    while (_queue.isNotEmpty) {
      final request = _queue.removeFirst();
      if (!request.done.isCompleted) request.done.complete();
    }
  }

  /// Resolves the on-device history store, or null when it is not available
  /// (DB not open yet, no keystore, running under a plain widget test). A null
  /// return is the graceful-degradation signal: the caller keeps working
  /// in-memory and simply skips persistence.
  Future<ChatHistoryRepository?> _history() async {
    try {
      return await ref.read(chatHistoryRepositoryProvider.future);
    } catch (_) {
      return null;
    }
  }

  /// Fire-and-forget persistence of a single [message]. NEVER awaited by the
  /// send flow, so it can neither block nor reorder a generation; any failure
  /// (store down) is swallowed so the conversation stays usable in-memory.
  void _persist(ChatMessage message) {
    unawaited(() async {
      final repo = await _history();
      if (repo == null) return;
      try {
        await repo.appendMessage(message);
      } catch (_) {
        // Best-effort: an in-memory message that fails to persist is still shown.
      }
    }());
  }

  /// Lets tests await the persisted-history overlay ([_hydratePersisted])
  /// deterministically. `ready` intentionally does NOT wait on it (see below).
  Future<void>? _persistedHydration;
  Future<void> get persistedReady => _persistedHydration ?? Future<void>.value();

  Future<void> _loadHistory() async {
    // Fast path (gates [ready]): the repository's own history (HTTP server /
    // on-device engine). NEVER gated on the async graph store, so the
    // conversation shows immediately and a store that is slow/unavailable to
    // open can never block hydration (or reorder the send flow).
    try {
      final history = await ref.read(chatRepositoryProvider).loadHistory();
      if (_disposed) return;
      if (history.isNotEmpty) state = state.copyWith(messages: history);
    } catch (_) {
      // History failing to load must not block sending new messages.
    }
    // Overlay the persisted on-device history as a DETACHED best-effort: it is
    // deliberately NOT awaited by [ready] so a graph store that opens slowly
    // (or never, e.g. a plain widget test with no platform channel) can never
    // block init. When it resolves it replaces the transcript with what
    // survived the last app restart. Onboarding seeding is chained AFTER it so
    // the "empty history" decision sees the persisted transcript, not just the
    // fast path.
    _persistedHydration = _hydratePersisted().then((_) => _maybeSeedOnboarding());
  }

  /// FIRST-RUN onboarding (roadmap SLICE C1 follow-up): when the chat opens with
  /// EMPTY history and the user has not told us their name yet, seed ONE scripted
  /// Axi greeting that introduces Axi and asks how to be called. Scripted +
  /// instant (never the model), and persisted as the first bubble so it does not
  /// re-post on a normal re-open; a full wipe (which clears history AND the user
  /// hub) naturally re-enables it on the next empty-history open.
  ///
  /// Also seeds [_userNameKnown] for the session: when a name is already on the
  /// hub the whole onboarding/capture path is disabled. Skipped entirely when
  /// the graph store is unavailable this launch (nothing to persist or read) —
  /// the chat still works and onboarding simply waits for a store.
  Future<void> _maybeSeedOnboarding() async {
    if (_disposed) return;
    final identity =
        await ref.read(chatContextBuilderProvider).userIdentity();
    if (_disposed) return;
    if (!identity.available) return; // no store this launch → wait.
    final known = identity.name != null && identity.name!.trim().isNotEmpty;
    _userNameKnown = known;
    if (known) return;
    // Name unknown: greet only on a truly empty transcript (first run / after a
    // wipe). An existing conversation with no name yet is left alone; a later
    // "me llamo …" can still be captured.
    if (state.messages.isNotEmpty) return;
    final greeting = ChatMessage(
      id: onboardingQuestionId,
      role: ChatRole.axi,
      text: _l10n().chatOnboardingGreeting,
      timestamp: DateTime.now(),
    );
    state = state.copyWith(messages: [greeting]);
    _persist(greeting);
  }

  /// Say something first, when there is something worth picking up.
  ///
  /// Nothing in the app ever started a conversation, which put the whole
  /// burden of remembering on the busiest person in the room. This is the
  /// first line on the screen — not a notification — and it is built from what
  /// is already in the graph, so it can only mention something the user
  /// actually said.
  ///
  /// NOT persisted: it is a greeting, not memory. It also never repeats within
  /// the day, because the last message's own timestamp says whether you have
  /// already been talking.
  Future<void> _maybeOpenWithSomething() async {
    if (_disposed || state.messages.isEmpty) return;
    try {
      final store = ref.read(localGraphStoreProvider).value;
      if (store == null) return;
      final nodes = await store.listNodesByKind('fact', limit: 30);
      final line = openingLine(
        [
          for (final n in nodes)
            if (n.label.trim().isNotEmpty)
              OpeningFact(
                label: n.label.trim(),
                at: n.occurredAt ?? n.createdAt,
                domain: n.domain,
              ),
        ],
        now: DateTime.now(),
        lastSpokeAt: state.messages.last.timestamp,
      );
      if (line == null || _disposed) return;
      state = state.copyWith(messages: [
        ...state.messages,
        ChatMessage(
          id: 'opener-${DateTime.now().microsecondsSinceEpoch}',
          role: ChatRole.axi,
          text: line,
          timestamp: DateTime.now(),
        ),
      ]);
    } catch (_) {
      // Best-effort: a greeting is never worth breaking the chat for.
    }
  }

  /// App-localized strings for the notifier (no [BuildContext] here): resolve the
  /// generated bundle from the app language the rest of the deterministic path
  /// (reminders, web-search) reads at send time.
  AppLocalizations _l10n() =>
      lookupAppLocalizations(Locale(ref.read(appLanguageCodeProvider)));

  /// True when the last visible bubble is Axi's onboarding name question — the
  /// signal that lets the NEXT user message be read as a bare name.
  bool _lastBubbleIsOnboardingQuestion() {
    final msgs = state.messages;
    return msgs.isNotEmpty &&
        msgs.last.role == ChatRole.axi &&
        msgs.last.id == onboardingQuestionId;
  }

  /// How many times to try reading the persisted transcript.
  ///
  /// It used to be ONE, and that one attempt happens on a cold start — exactly
  /// when the encrypted store is still being opened and is most likely to fail.
  /// When it did, the chat sat empty until the app was killed and relaunched,
  /// because relaunching is what retried it. That is the bug the user lived
  /// with for weeks.
  ///
  /// Bounded, though: a store that is genuinely gone must not become a loop
  /// that keeps a phone awake.
  static const int _hydrationAttempts = 4;

  /// The pause between attempts, held so leaving the screen cancels it.
  ///
  /// A bare `Future.delayed` keeps a Timer alive after the widget tree is
  /// gone — the test binding refuses it, and on a device it is a wake-up
  /// scheduled for a screen nobody is looking at any more.
  Timer? _hydrationTimer;
  Completer<void>? _hydrationWait;

  Future<void> _pause(Duration duration) {
    _hydrationTimer?.cancel();
    final waiter = Completer<void>();
    _hydrationWait = waiter;
    _hydrationTimer = Timer(duration, () {
      if (!waiter.isCompleted) waiter.complete();
    });
    return waiter.future;
  }

  Future<void> _hydratePersisted() async {
    for (var attempt = 0; attempt < _hydrationAttempts; attempt++) {
      if (_disposed) return;
      try {
        final repo = await _history();
        if (repo != null) {
          final persisted = await repo.loadMessages();
          if (_disposed) return;
          if (persisted.isNotEmpty) {
            state = state.copyWith(messages: persisted, hydrating: false);
            return;
          }
          // Read fine and there is genuinely nothing: a new user. Settle, or
          // the screen would spin for ever on an empty conversation.
          state = state.copyWith(hydrating: false);
          return;
        }
      } catch (_) {
        // Fall through to the wait and try again.
      }
      // Checked again right here: the awaits above can span a screen being
      // closed, and starting a timer after that leaves one pending on a widget
      // tree that is already gone.
      if (_disposed) return;
      // Growing pause: an encrypted store opens in a moment, not instantly,
      // and hammering it does not make it faster.
      await _pause(Duration(milliseconds: 150 * (attempt + 1)));
      if (_disposed) return;
    }
    if (_disposed) return;
    // Gave up. The chat still works; it just could not recover what was said
    // before — and the screen is told, instead of pretending it is empty.
    state = state.copyWith(hydrating: false);
  }

  /// Clears the visible conversation and the persisted on-device history for
  /// the default conversation. In-memory clears immediately; persistence is
  /// best-effort.
  Future<void> clearHistory() async {
    if (_disposed) return;
    state = state.copyWith(messages: const []);
    final repo = await _history();
    if (repo == null) return;
    try {
      await repo.clearConversation();
    } catch (_) {
      // Best-effort: the visible conversation is already cleared.
    }
  }

  Future<void> sendMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Future<void>.value();
    // Captured BEFORE the optimistic append (which would otherwise become the
    // last bubble): was the last bubble Axi's onboarding question? If so a bare
    // reply is treated as the user's name.
    final answeringNamePrompt =
        !_userNameKnown && _lastBubbleIsOnboardingQuestion();
    final userMessage = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: trimmed,
      timestamp: DateTime.now(),
      status: ChatMessageStatus.sending,
    );
    // Optimistic append: the user message is visible immediately (as "sending",
    // a clock), before the repository call resolves. `sending: true` keeps the
    // "escribiendo…" indicator up until the whole queue drains.
    state = state.copyWith(messages: [...state.messages, userMessage], sending: true, error: null);
    _persist(userMessage);
    // Roadmap slice C2 — deterministic reminder intent (laptop parity: the
    // engine also resolves "recuérdame…" with its regex parser BEFORE the
    // LLM). Guarded twice so normal messages are untouched: the parser's
    // trigger must match AND the time must fully resolve; anything else
    // (including a store failure inside the handler) takes the normal model
    // path below.
    final reminderIntent = _tryParseReminderIntent(trimmed);
    if (reminderIntent != null) {
      return _handleReminderIntent(trimmed, userMessage, reminderIntent);
    }
    // First-run onboarding name capture (DETERMINISTIC — never the model). While
    // the name is unknown, a SYNCHRONOUS parse decides whether this message even
    // looks like a name: only then do we take the async capture path (which reads
    // + writes the user hub). A normal message parses to null here and goes
    // STRAIGHT to the model send — no store read, no extra frame, no async hop —
    // so onboarding never adds latency to (or reorders) ordinary chat.
    if (!_userNameKnown &&
        parseUserName(trimmed, bareAllowed: answeringNamePrompt) != null) {
      return _maybeCaptureNameThenSend(
        trimmed,
        userMessage,
        answeringNamePrompt: answeringNamePrompt,
      );
    }
    return _answer(trimmed, userMessage);
  }

  /// Answers one user turn [text] (typed, dictated, or re-routed): the
  /// DETERMINISTIC capture gets first refusal, the model answers everything
  /// else. Shared by every text-turn entry point so they never drift.
  ///
  /// The capture triage ([ChatContextBuilder.looksCapturable]) is SYNCHRONOUS,
  /// model-free and store-free, so an ordinary message goes straight to the
  /// model with no extra async hop or store read.
  Future<void> _answer(String rawText, ChatMessage userMessage) {
    // WHO this turn is about, tracked in Dart rather than left to the model.
    //
    // "tiene dos hijos" names nobody, so the capture layer had nothing to
    // attach it to and the fact either vanished or landed on whoever was
    // handy. Naming the subject before the sentence is read fixes that
    // without touching a single capture rule.
    //
    // `resolveConversationSubject` returns null when it is NOT sure — two
    // people named, or a thread gone cold — and null means "change nothing".
    // Unattributed is recoverable; misattributed is not, because nobody goes
    // looking for a fact filed under the wrong person.
    if (_knownPeople.isEmpty) _loadKnownPeople();
    _subject = resolveConversationSubject(
      message: rawText,
      knownPeople: _knownPeople,
      now: DateTime.now(),
      previous: _subject,
    );
    final text = attributeToSubject(rawText, _subject);

    // A CORRECTION comes before everything that stores. Left to the capture
    // path, "no, Mateo tiene 9" was written as a SECOND entry beside "Mateo
    // tiene 8", and recall could then return either — a memory that
    // contradicts itself is worse than one that was simply wrong.
    if (looksLikeCorrection(rawText)) {
      return _applyCorrectionOrModel(rawText, userMessage);
    }

    // "¿A qué hora…?" goes FIRST. Measured on the Pixel: placed after the
    // capture triage, "a qué hora me pesé ayer" was read as a weight entry
    // ("pesé") and handed to the model, which answered 15:16 for something
    // logged at 09:16. A QUESTION is never a capture, and the record is the
    // only thing allowed to state an hour.
    if (asksAboutTime(rawText)) {
      return _answerWhenOrModel(rawText, userMessage);
    }

    // What was just said ABOUT a person, when we know who that is. This is
    // the dinner-two-months-from-now feature: "su hijo Mateo tiene 8" is what
    // makes someone feel remembered, and the generic capture stored it as an
    // orphan sentence attached to nobody.
    //
    // Read in Dart, never from the model: an invented detail about someone's
    // family gets repeated to their face.
    final subject = _subject;
    if (subject != null && !subject.isQuestion) {
      final facts = personFactsIn(rawText, subject: subject.name);
      if (facts.isNotEmpty) {
        return _rememberPersonFactsOrModel(facts, text, userMessage);
      }
    }

    // A stated BOND is stored before anything else looks at the turn. The
    // generic capture accepted the sentence and wrote nothing from it, so being
    // told about someone's sister left no trace at all.
    final bond = kinshipStatement(text);
    if (bond != null) return _rememberBondOrModel(bond, text, userMessage);
    if (_looksCapturable(text)) return _captureThenAnswer(text, userMessage);
    // A KINSHIP question is answered from the graph, never by the model.
    //
    // Measured on the test Pixel: with "mi hermana se llama Laura" stored and
    // the recall provably correct, the ~2B model answered "Laura es tu
    // esposa". Four rounds of prompt rules only moved the error around. Getting
    // someone's family wrong is the one mistake a person will not forgive, and
    // it is also the easiest thing to read straight out of the stored sentence.
    //
    // Falls through whenever it is not certain — see `answerAboutPerson`.
    if (personAskedAbout(text) != null) {
      return _answerAboutPersonOrModel(text, userMessage);
    }
    return _sendTextToModel(text, userMessage);
  }

  /// Apply a spoken correction, or fall back to the model when there is
  /// nothing to correct.
  Future<void> _applyCorrectionOrModel(
    String text,
    ChatMessage userMessage,
  ) async {
    final corrected = correctionPayload(text);
    // "Me equivoqué" alone says something is wrong without saying what is
    // right. Deleting on that would erase a real fact and put nothing back.
    if (corrected == null) return _sendTextToModel(text, userMessage);
    try {
      final ack = await ref
          .read(chatContextBuilderProvider)
          .applyCorrection(corrected, subject: _subject?.name);
      if (ack == null) return _sendTextToModel(text, userMessage);
      if (_disposed) return;
      final reply = ChatMessage(
        id: 'fix-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.axi,
        text: ack,
        timestamp: DateTime.now(),
      );
      state = state.copyWith(messages: [...state.messages, reply]);
      _persist(reply);
    } catch (_) {
      return _sendTextToModel(text, userMessage);
    }
  }

  /// Answer a time question from the record; fall back to the model when the
  /// record cannot answer it. Never guesses an hour.
  Future<void> _answerWhenOrModel(String text, ChatMessage userMessage) async {
    try {
      final answer =
          await ref.read(chatContextBuilderProvider).answerWhenAsked(text);
      if (answer == null) return _sendTextToModel(text, userMessage);
      if (_disposed) return;
      final reply = ChatMessage(
        id: 'when-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.axi,
        text: answer,
        timestamp: DateTime.now(),
      );
      state = state.copyWith(messages: [...state.messages, reply]);
      _persist(reply);
    } catch (_) {
      return _sendTextToModel(text, userMessage);
    }
  }

  /// Store what was said about a person; fall back to the model if nothing
  /// could be written.
  ///
  /// Never acknowledges a save that did not happen — the one lie this codebase
  /// treats as unforgivable, and here it would be a lie the user only finds out
  /// about in front of the person whose life was supposedly remembered.
  Future<void> _rememberPersonFactsOrModel(
    List<PersonFact> facts,
    String text,
    ChatMessage userMessage,
  ) async {
    try {
      final ack =
          await ref.read(chatContextBuilderProvider).rememberPersonFacts(facts);
      if (ack == null) return _sendTextToModel(text, userMessage);
      if (_disposed) return;
      final reply = ChatMessage(
        id: 'person-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.axi,
        text: ack,
        timestamp: DateTime.now(),
      );
      state = state.copyWith(messages: [...state.messages, reply]);
      _persist(reply);
      // A new person may have appeared, so the next turn can recognise them.
      _loadKnownPeople();
    } catch (_) {
      return _sendTextToModel(text, userMessage);
    }
  }

  /// Store a stated bond; fall back to the model if it could not be written.
  Future<void> _rememberBondOrModel(
    ({String bond, String name}) stated,
    String text,
    ChatMessage userMessage,
  ) async {
    try {
      final ack = await ref
          .read(chatContextBuilderProvider)
          .rememberKinship(bond: stated.bond, name: stated.name);
      // Null means nothing was stored: never acknowledge a save that did not
      // happen — that is the one lie this codebase treats as unforgivable.
      if (ack == null) return _sendTextToModel(text, userMessage);
      if (_disposed) return;
      final reply = ChatMessage(
        id: 'bond-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.axi,
        text: ack,
        timestamp: DateTime.now(),
      );
      state = state.copyWith(messages: [...state.messages, reply]);
      _persist(reply);
    } catch (_) {
      return _sendTextToModel(text, userMessage);
    }
  }

  /// Try the deterministic person answer; hand over to the model if unsure.
  Future<void> _answerAboutPersonOrModel(
    String text,
    ChatMessage userMessage,
  ) async {
    try {
      final name = personAskedAbout(text)!;
      final facts = await ref.read(chatContextBuilderProvider).factsMentioning(name);
      final answer = answerAboutPerson(
        name: name,
        facts: facts,
        languageCode: ref.read(appLanguageCodeProvider),
      );
      if (answer == null) return _sendTextToModel(text, userMessage);
      if (_disposed) return;
      final reply = ChatMessage(
        id: 'person-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.axi,
        text: answer,
        timestamp: DateTime.now(),
      );
      state = state.copyWith(messages: [...state.messages, reply]);
      _persist(reply);
    } catch (_) {
      // Any failure here is a reason to use the model, never to lose the turn.
      return _sendTextToModel(text, userMessage);
    }
  }

  /// Sync guard for [_answer]; a builder failure degrades to "not capturable"
  /// so a broken/absent memory stack can never block a normal send.
  bool _looksCapturable(String text) {
    try {
      return ref.read(chatContextBuilderProvider).looksCapturable(text);
    } catch (_) {
      return false;
    }
  }

  /// CONFIRM WHAT WAS RECORDED (laptop parity, `dashboard.py`: a structured
  /// capture answers "Anotado en salud como vital: …" and short-circuits the
  /// brain). Runs the DETERMINISTIC capture FIRST; when it wrote something, its
  /// summary becomes Axi's reply — instant, no model call, and always exactly
  /// what landed in the domains list, per domain AND per person. Nothing
  /// captured → the ordinary model path answers the turn as before.
  ///
  /// Needs NO model, so it works with the on-device brain disabled or absent.
  Future<void> _captureThenAnswer(String text, ChatMessage userMessage) async {
    final conversationUuid = await _conversationUuid();
    if (_disposed) return;
    CaptureSummary summary;
    try {
      summary = await ref.read(chatContextBuilderProvider).captureTurn(
            text,
            sourceMessageId: userMessage.id,
            sourceConversationUuid: conversationUuid,
          );
    } catch (_) {
      summary = const CaptureSummary.empty(); // memory down → model answers.
    }
    if (_disposed) return;
    if (summary.isEmpty) {
      // Nothing to confirm → normal model reply. The capture already ran, so
      // the write-back is handed its summary and never captures twice.
      await _sendTextToModel(
        text,
        userMessage,
        captured: summary,
        conversationUuid: conversationUuid,
      );
      return;
    }
    final reply = ChatMessage(
      id: 'capture-ack-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.axi,
      text: _captureAckText(summary),
      timestamp: DateTime.now(),
    );
    // ORDERING: while a generation is draining (e.g. a message typed during a
    // voice note's transcription), appending the ack directly would interleave
    // it between that pending user turn and its model reply — breaking the
    // "reply directly follows its user turn" invariant [pairedReplyOf] (and
    // its delete cascade) relies on, and dropping the typing indicator early.
    // Route the ack through the SAME FIFO as a no-model request that resolves
    // instantly. When the queue is idle (the normal case) append directly, so
    // the ack stays instant.
    if (_draining || _queue.isNotEmpty) {
      await _enqueue(_OutgoingRequest(
        userMessageId: userMessage.id,
        run: () async => reply,
        errorPrefix: 'No se pudo confirmar la captura',
        onReply: (r) => _recordAfterReply(
          text,
          r.text,
          summary: summary,
          sourceMessageId: userMessage.id,
          conversationUuid: conversationUuid,
        ),
      ));
      return;
    }
    _setStatus(userMessage.id, ChatMessageStatus.delivered);
    state = state.copyWith(messages: [...state.messages, reply], sending: false);
    _persist(reply);
    // Store the exchange + run the MODEL-based open-ended extractor AFTER the
    // ack is on screen (fire-and-forget), so the model never delays the reply.
    _recordAfterReply(
      text,
      reply.text,
      summary: summary,
      sourceMessageId: userMessage.id,
      conversationUuid: conversationUuid,
    );
  }

  /// The deterministic acknowledgment text: one
  /// `Anotado en <Dominio>[ (Persona)]: <lo anotado>.` line per captured entry,
  /// grouped by domain so a multi-topic / multi-person turn shows the SEPARATION
  /// the user needs to spot a mis-attribution. Terse and factual — nothing the
  /// capture did not write.
  String _captureAckText(CaptureSummary summary) {
    final l10n = _l10n();
    return _groupedByDomain(summary.entries).map((entry) {
      final domain = _domainLabel(entry.domainKey);
      final subject = entry.subject?.trim();
      return subject == null || subject.isEmpty
          ? l10n.chatCaptureAck(domain, entry.title)
          : l10n.chatCaptureAckSubject(domain, subject, entry.title);
    }).join('\n');
  }

  /// Entries grouped per domain, keeping each domain's FIRST-appearance order
  /// and the capture order inside it (so the user's own reading precedes the one
  /// he dictated for someone else, exactly as he said them).
  static List<CaptureEntry> _groupedByDomain(List<CaptureEntry> entries) {
    final byDomain = <String, List<CaptureEntry>>{};
    for (final entry in entries) {
      byDomain.putIfAbsent(entry.domainKey, () => <CaptureEntry>[]).add(entry);
    }
    return byDomain.values.expand((group) => group).toList();
  }

  /// The domain's display title from the shared registry (one source of truth
  /// with the domains list / "Mi vida"); an unknown key degrades to itself.
  static String _domainLabel(String domainKey) {
    for (final descriptor in domainDescriptors) {
      if (descriptor.key == domainKey) return descriptor.title;
    }
    return domainKey;
  }

  /// The persisted conversation's uuid (provenance stamp), best-effort: null
  /// when no store is available — the write-back then goes unstamped and recall
  /// still works.
  Future<String?> _conversationUuid() async {
    try {
      final repo = await _history();
      return repo == null ? null : await repo.conversationUuid();
    } catch (_) {
      return null;
    }
  }

  /// Normal model send for a text turn: the FIFO enqueue + C1 memory write-back
  /// (on-device only). Shared by the default path and the onboarding fall-through
  /// so the two never drift.
  ///
  /// [captured] is the summary of a capture that ALREADY ran for this turn (see
  /// [_captureThenAnswer]); passing it keeps the write-back from capturing the
  /// same text twice.
  Future<void> _sendTextToModel(
    String trimmed,
    ChatMessage userMessage, {
    CaptureSummary? captured,
    String? conversationUuid,
  }) {
    return _enqueue(_OutgoingRequest(
      userMessageId: userMessage.id,
      run: () => ref.read(chatRepositoryProvider).sendMessage(trimmed),
      errorPrefix: 'No se pudo enviar el mensaje',
      userText: trimmed,
      // SLICE C1 write-back: after Axi replies, persist the exchange to memory
      // (conversation turn + a fact when the user stated something personal) so
      // Axi remembers next time. On-device only; best-effort and fire-and-forget
      // (see `_recordTurn`) so it never blocks or reorders the FIFO send flow.
      onReply: ref.read(localModelEnabledProvider)
          ? (reply) => captured == null
              ? _recordTurn(trimmed, reply.text,
                  sourceMessageId: userMessage.id)
              : _recordAfterReply(
                  trimmed,
                  reply.text,
                  summary: captured,
                  sourceMessageId: userMessage.id,
                  conversationUuid: conversationUuid,
                )
          : null,
    ));
  }

  /// Attempt a deterministic user-name capture for [trimmed]; on success store
  /// it on the user hub and answer with a scripted confirmation (NO model call),
  /// otherwise fall through to the normal model send so the message is answered
  /// as usual. NEVER blocks normal chat.
  Future<void> _maybeCaptureNameThenSend(
    String trimmed,
    ChatMessage userMessage, {
    required bool answeringNamePrompt,
  }) async {
    String? name;
    try {
      name = await ref.read(chatContextBuilderProvider).captureUserName(
            trimmed,
            answeringNamePrompt: answeringNamePrompt,
          );
    } catch (_) {
      name = null; // store unavailable / builder error → treat as no capture.
    }
    if (_disposed) return;
    if (name == null) {
      // Not a name → ordinary chat (recorded + answered by the model).
      await _sendTextToModel(trimmed, userMessage);
      return;
    }
    // Captured: mark known, confirm deterministically, skip the model.
    _userNameKnown = true;
    _setStatus(userMessage.id, ChatMessageStatus.delivered);
    final reply = ChatMessage(
      id: 'onboarding-name-confirm-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.axi,
      text: _l10n().chatOnboardingNameConfirm(name),
      timestamp: DateTime.now(),
    );
    state = state.copyWith(messages: [...state.messages, reply], sending: false);
    _persist(reply);
  }

  /// Parse [text] as a fully-resolved reminder request against the device
  /// clock (`clockProvider` seam). Returns null unless BOTH the reminder
  /// trigger matched and a due instant was resolved — a trigger without a
  /// parseable time falls through to the model, which can ask for one.
  ParsedReminder? _tryParseReminderIntent(String text) {
    try {
      final parsed = parseReminder(text, now: ref.read(clockProvider).now());
      if (parsed == null || parsed.dueAt == null) return null;
      return parsed;
    } catch (_) {
      // A parser bug must never break normal chat.
      return null;
    }
  }

  /// Create the LOCAL reminder and answer with a DETERMINISTIC confirmation —
  /// no LLM call (laptop parity: creation is regex + store, not the brain).
  /// If the local store/scheduler is unavailable, degrade to the normal model
  /// flow with the ORIGINAL text so the message is never lost.
  Future<void> _handleReminderIntent(
    String original,
    ChatMessage userMessage,
    ParsedReminder parsed,
  ) async {
    LocalReminder created;
    try {
      final service = await ref.read(localRemindersServiceProvider.future);
      created = await service.create(
        text: parsed.text.isEmpty ? original : parsed.text,
        dueAt: parsed.dueAt!,
        recurrence: parsed.recurrence,
      );
    } catch (_) {
      // Store not ready (no keystore / plain test) → normal answer flow (the
      // deterministic capture still gets first refusal, then the model).
      if (_disposed) return;
      await _answer(original, userMessage);
      return;
    }
    if (_disposed) return;
    _setStatus(userMessage.id, ChatMessageStatus.delivered);
    final reply = ChatMessage(
      id: 'local-reminder-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.axi,
      text: _reminderConfirmText(created),
      timestamp: DateTime.now(),
    );
    state = state.copyWith(messages: [...state.messages, reply], sending: false);
    _persist(reply);
  }

  /// Deterministic confirmation bubble ("Listo, te recuerdo …"). Neutral
  /// Spanish by default; English when the app language is English — same
  /// send-time language read the web-search sources label uses.
  String _reminderConfirmText(LocalReminder reminder) {
    String two(int n) => n.toString().padLeft(2, '0');
    final due = reminder.dueAt;
    final time = '${two(due.hour)}:${two(due.minute)}';
    final date = '${two(due.day)}/${two(due.month)}/${due.year}';
    final english = ref.read(appLanguageCodeProvider) == 'en';
    if (reminder.recurrence == ReminderRecurrence.daily) {
      return english
          ? 'Done — I will remind you "${reminder.text}" every day at $time. ⏰'
          : 'Listo, te recuerdo "${reminder.text}" todos los días a las $time. ⏰';
    }
    return english
        ? 'Done — I will remind you "${reminder.text}" on $date at $time. ⏰'
        : 'Listo, te recuerdo "${reminder.text}" el $date a las $time. ⏰';
  }

  /// Fire-and-forget memory write-back for one completed text turn. NEVER
  /// awaited by the drain loop, so it can neither block nor reorder a
  /// generation; the builder swallows every failure internally.
  ///
  /// Data-control kit: passes PROVENANCE (the user message id + the
  /// conversation uuid, resolved best-effort) so derived facts/turns are
  /// stamped and "Eliminar conversación/mensaje" can cascade to them.
  void _recordTurn(String userText, String axiText, {String? sourceMessageId}) {
    unawaited(() async {
      try {
        String? conversationUuid;
        final repo = await _history();
        if (repo != null) {
          try {
            conversationUuid = await repo.conversationUuid();
          } catch (_) {
            // No store → unstamped write-back (recall still works).
          }
        }
        await ref.read(chatContextBuilderProvider).recordTurn(
              userText: userText,
              axiText: axiText,
              sourceMessageId: sourceMessageId,
              sourceConversationUuid: conversationUuid,
            );
      } catch (_) {
        // Disposed mid-flight / builder unavailable — best-effort by contract.
      }
    }());
  }

  /// Fire-and-forget write-back for a turn whose DETERMINISTIC capture already
  /// ran ([_captureThenAnswer]): stores the exchange itself and then lets the
  /// MODEL-based open-ended extractor run — after the reply is already on
  /// screen, so it can never add latency to the acknowledgment. The extractor is
  /// skipped unless the on-device brain is enabled (it is the only step here
  /// that needs a model).
  void _recordAfterReply(
    String userText,
    String axiText, {
    required CaptureSummary summary,
    String? sourceMessageId,
    String? conversationUuid,
  }) {
    final modelEnabled = ref.read(localModelEnabledProvider);
    unawaited(() async {
      try {
        final builder = ref.read(chatContextBuilderProvider);
        await builder.recordConversationTurn(
          userText: userText,
          axiText: axiText,
          sourceMessageId: sourceMessageId,
          sourceConversationUuid: conversationUuid,
        );
        if (!modelEnabled) return;
        await builder.extractOpenEnded(
          userText: userText,
          axiText: axiText,
          summary: summary,
        );
      } catch (_) {
        // Disposed mid-flight / builder unavailable — best-effort by contract.
      }
    }());
  }

  /// The Axi reply that would be deleted TOGETHER with [message] (pairing
  /// rule): when [message] is a USER turn, its reply is the NEXT message in
  /// the transcript IF that next message is Axi's — the FIFO appends user
  /// msg → reply, so replies always directly follow their user turn. Null
  /// when [message] is Axi's, is the last bubble, or the next bubble is
  /// another user message (e.g. queued sends still awaiting their replies).
  ChatMessage? pairedReplyOf(ChatMessage message) {
    if (message.role != ChatRole.user) return null;
    final messages = state.messages;
    final index = messages.indexWhere((m) => m.id == message.id);
    if (index < 0 || index + 1 >= messages.length) return null;
    final next = messages[index + 1];
    return next.role == ChatRole.axi ? next : null;
  }

  /// Deletes [message] — and, when it is a USER turn, ALSO the Axi reply that
  /// answered it ([pairedReplyOf]): a reply without its question would keep a
  /// bubble with no context for why Axi said that. Deleting an Axi reply alone
  /// leaves the user message intact (context flows forward). Both bubbles drop
  /// immediately; then (best-effort) each one's persisted node, vectors, voice
  /// clip, and provenance-stamped derived facts cascade via
  /// [ChatHistoryRepository.deleteMessage].
  Future<void> deleteMessage(ChatMessage message) async {
    if (_disposed) return;
    final reply = pairedReplyOf(message);
    final doomedIds = {message.id, if (reply != null) reply.id};
    state = state.copyWith(
      messages: [
        for (final m in state.messages)
          if (!doomedIds.contains(m.id)) m,
      ],
    );
    final repo = await _history();
    if (repo == null) return;
    try {
      await repo.deleteMessage(message);
      if (reply != null) await repo.deleteMessage(reply);
    } catch (_) {
      // Best-effort: the bubbles are already gone; persistence degrades.
    }
  }

  /// Deletes the WHOLE conversation with cascade (messages, derived facts,
  /// turn nodes, vectors, voice clips) via
  /// [ChatHistoryRepository.deleteConversation]. The visible transcript
  /// clears immediately; persistence is best-effort.
  Future<void> deleteConversation() async {
    if (_disposed) return;
    state = state.copyWith(messages: const []);
    final repo = await _history();
    if (repo == null) return;
    try {
      await repo.deleteConversation();
    } catch (_) {
      // Best-effort: the visible conversation is already cleared.
    }
  }

  /// Advances an outgoing user message's delivery [status] in place (WhatsApp
  /// checkmarks) without disturbing the rest of the conversation.
  void _setStatus(String id, ChatMessageStatus status) {
    state = state.copyWith(
      messages: [
        for (final m in state.messages) if (m.id == id) m.copyWith(status: status) else m,
      ],
    );
  }

  /// Sends one or more attached [images] (optional [caption]) to Axi in a
  /// single turn. The photos are shown as one user bubble immediately
  /// (optimistic), then routed to the repository's VISION path (`sendImages`) —
  /// on-device this reaches the model's `generateWithImages`. No-op if [images]
  /// is empty.
  Future<void> sendImages(List<Uint8List> images, {String caption = ''}) {
    if (images.isEmpty) return Future<void>.value();
    final trimmed = caption.trim();
    final userMessage = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: trimmed,
      timestamp: DateTime.now(),
      kind: ChatMessageKind.image,
      images: images,
      status: ChatMessageStatus.sending,
    );
    state = state.copyWith(messages: [...state.messages, userMessage], sending: true, error: null);
    _persist(userMessage);
    return _enqueue(_OutgoingRequest(
      userMessageId: userMessage.id,
      run: () => ref.read(chatRepositoryProvider).sendImages(trimmed, images),
      errorPrefix: 'No se pudo enviar la imagen',
    ));
  }

  /// La última puerta antes de que la respuesta se vea.
  ///
  /// Medido en el Pixel el 2026-08-20: a "Nos hicimos novios el 12 de mayo del
  /// 2008" el modelo contestaba esa misma frase, y a lo siguiente "¿Qué
  /// necesitas, Héctor?". Un eco no es conversar, y esa cortesía después de
  /// que alguien te cuenta algo suyo es peor todavía.
  ///
  /// El prompt YA pedía otra cosa; un modelo de este tamaño no obedece esa
  /// clase de regla y cada regla nueva afloja la anterior. Así que la decisión
  /// se toma aquí, mirando lo que devolvió.
  ChatMessage _worthSaying(String? userText, ChatMessage reply) {
    if (userText == null || userText.isEmpty) return reply;
    final bad = isEchoReply(userText: userText, reply: reply.text) ||
        isEmptyPleasantry(reply.text);
    if (!bad) return reply;
    return reply.copyWith(text: acknowledgeStatement(userText));
  }

  /// Appends [request] to the FIFO [_queue] and (re)starts the [_drain] loop.
  /// Returns a future that completes when THIS request has finished (its reply
  /// appended or its error surfaced), so callers can still `await` a single
  /// send even though a shared loop does the work.
  Future<void> _enqueue(_OutgoingRequest request) {
    _queue.add(request);
    unawaited(_drain());
    return request.done.future;
  }

  /// Processes the [_queue] strictly one item at a time. Re-entrant-safe: a send
  /// that arrives while a drain is already running just adds to the queue and
  /// returns — the active loop picks it up. This is what guarantees NO two model
  /// calls ever overlap on the single on-device session.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (!_disposed && _queue.isNotEmpty) {
        final request = _queue.removeFirst();
        // Wait for a real frame to rasterize before handing off. The on-device
        // path runs a synchronous, main-isolate-blocking FFI call, so a mere
        // microtask yield never lets the "escribiendo…" indicator (bound to
        // `sending: true`) paint before the freeze. `endOfFrame` guarantees the
        // indicator is on screen before generation blocks the isolate.
        await WidgetsBinding.instance.endOfFrame;
        // Disposed while awaiting the frame → unblock the caller and stop; never
        // start a generation or mutate state on a torn-down notifier.
        if (_disposed) {
          if (!request.done.isCompleted) request.done.complete();
          return;
        }
        try {
          final replyFuture = request.run();
          // Handed to the engine/repository → single ✓.
          _setStatus(request.userMessageId, ChatMessageStatus.sent);
          final reply = _worthSaying(request.userText, await replyFuture);
          // Disposed mid-generation → done is completed in `finally`; bail
          // before appending so we never write to a disposed notifier.
          if (_disposed) return;
          // Axi's reply came back → double ✓✓, then append the reply. Keep
          // `sending` true; it flips false only once the queue is fully drained.
          _setStatus(request.userMessageId, ChatMessageStatus.delivered);
          state = state.copyWith(messages: [...state.messages, reply]);
          _persist(reply);
          // Best-effort memory write-back (unawaited inside the callback), fired
          // only once the reply is in hand so it never delays the next turn.
          request.onReply?.call(reply);
        } on ChatException catch (error) {
          // Keep the already-appended user message (left at "sent"); do not add
          // a phantom reply. Continue draining any queued items.
          if (_disposed) return;
          state = state.copyWith(error: error.message);
        } catch (error) {
          if (_disposed) return;
          state = state.copyWith(error: '${request.errorPrefix}: $error');
        } finally {
          if (!request.done.isCompleted) request.done.complete();
        }
      }
    } finally {
      _draining = false;
      // The queue is empty and no generation is in flight → drop the indicator.
      // PRESERVE any error the loop surfaced: `copyWith` clears `error` unless
      // it is passed through, so a bare `copyWith(sending: false)` here would
      // wipe the failure message before the UI ever showed it. Never touch
      // state after dispose.
      if (!_disposed) state = state.copyWith(sending: false, error: state.error);
    }
  }

  /// Neutral-Spanish fallback Axi gives to a voice note when it CANNOT be
  /// transcribed on-device (the ~80 MB voice model isn't downloaded yet, or the
  /// transcription failed/was empty). Rendered as a normal Axi text bubble (so
  /// the 🔊 speak button works on it too). No voseo. The reply invites the user
  /// to download the model — the UI exposes the download affordance via
  /// [downloadSttModel] / `sttModelDownloadProvider`.
  static const String voiceNotePlaceholderReply =
      'Todavía no puedo escuchar esta nota de voz: necesito descargar el modelo '
      'de voz primero. Descárgalo para transcribir tus notas de voz, o '
      'escríbeme lo que necesitas. 🙏';

  /// Lets tests await the async voice-note processing ([_processVoiceNote])
  /// deterministically, mirroring [ready].
  Future<void>? _voiceProcessing;
  Future<void> get voiceProcessed => _voiceProcessing ?? Future<void>.value();

  /// Appends a recorded voice note as a local user bubble (WhatsApp-style),
  /// then transcribes it ON-DEVICE and routes the transcript to Axi.
  ///
  /// Roadmap slice B2 (on-device STT): the voice bubble is shown immediately
  /// (flagged [transcriptionPending]); then [_processVoiceNote] runs the offline
  /// Whisper recognizer over the WAV. On success the transcript is written onto
  /// the voice bubble — which IS the user turn — and routed to the repository
  /// through the same FIFO queue a typed message uses (memory write-back,
  /// persistence, real LLM reply) WITHOUT appending a second user text bubble.
  /// If the model isn't downloaded yet or transcription fails/comes back empty,
  /// we DEGRADE GRACEFULLY to a static neutral-Spanish reply
  /// ([voiceNotePlaceholderReply]) — the note is never lost and nothing hangs.
  ///
  /// [audioPath] may be null when a very short/empty take produced no file: the
  /// bubble (and Axi's fallback reply) STILL appear so the note never silently
  /// vanishes — the voice bubble just has no playable clip. Only an intentional
  /// slide-to-cancel (handled in the UI) discards a take entirely.
  void addVoiceNote(String? audioPath, Duration duration) {
    final now = DateTime.now();
    final noteId = 'local-voice-${now.microsecondsSinceEpoch}';
    final note = ChatMessage(
      id: noteId,
      role: ChatRole.user,
      text: '',
      timestamp: now,
      kind: ChatMessageKind.voice,
      audioPath: audioPath,
      audioDuration: duration,
      transcriptionPending: true,
    );
    state = state.copyWith(messages: [...state.messages, note]);
    _voiceProcessing = _processVoiceNote(note);
  }

  /// Transcribes the voice [note] on-device and, on success, shows the
  /// transcript on the voice bubble and sends it to Axi. Falls back to a
  /// canned reply on any miss. NEVER throws — a failure just degrades.
  ///
  /// The bubble's persistence is deferred to this flow's TERMINAL branches so
  /// it is stored exactly ONCE (the history store is append-only): with its
  /// transcript when transcription succeeds, or still pending when the flow
  /// degrades. Always by audio-path reference, never the bytes.
  Future<void> _processVoiceNote(ChatMessage note) async {
    final audioPath = note.audioPath;
    // No clip (very short/empty take) → nothing to transcribe; fall back.
    if (audioPath == null) {
      _persist(note);
      _appendVoiceFallback();
      return;
    }
    // Authoritative readiness probe (not the download notifier's cached state,
    // which may not have hydrated yet): is the model actually on disk?
    final model = await ref.read(sttModelGatewayProvider).installedModel();
    if (_disposed) {
      _persist(note);
      return;
    }
    if (model == null) {
      // Not downloaded yet → graceful fallback; the reply invites a download.
      _persist(note);
      _appendVoiceFallback();
      return;
    }

    String transcript;
    try {
      final languageCode = ref.read(appLanguageCodeProvider);
      final raw = await ref.read(speechToTextProvider).transcribe(audioPath, languageCode: languageCode);
      transcript = raw.trim();
    } catch (_) {
      // Recognizer failed to load / decode error → never hang, never lose the
      // note: fall back to the canned reply.
      _persist(note);
      if (_disposed) return;
      _appendVoiceFallback();
      return;
    }
    if (_disposed) {
      _persist(note);
      return;
    }
    // Empty transcript (silence / unintelligible) → don't send an empty turn.
    if (transcript.isEmpty) {
      _persist(note);
      _appendVoiceFallback();
      return;
    }

    // Show what Axi heard on the voice bubble itself. The voice bubble IS the
    // user turn — no second (text) user bubble is appended for the transcript.
    final transcribed = _setVoiceTranscript(note.id, transcript);
    if (transcribed != null) _persist(transcribed);
    // Route the transcript through the SAME pipeline a typed message takes:
    // the FIFO [_queue] (single on-device session, strictly serial), the
    // active repository stack (C1 context preamble + B4 web-search decorator
    // both live inside `chatRepositoryProvider.sendMessage`), delivery ticks
    // on the voice bubble, C1 memory write-back, and persistence of the reply.
    // A dictated log ("122 77 55 pulsos") is confirmed deterministically here
    // too — same `_answer` triage a typed turn takes.
    state = state.copyWith(sending: true, error: null);
    await _answer(transcript, note);
  }

  /// Appends the neutral-Spanish fallback reply as a normal Axi text bubble.
  void _appendVoiceFallback() {
    if (_disposed) return;
    final reply = ChatMessage(
      id: 'local-voice-reply-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.axi,
      text: voiceNotePlaceholderReply,
      timestamp: DateTime.now(),
    );
    state = state.copyWith(messages: [...state.messages, reply]);
    _persist(reply);
  }

  /// Stores [transcript] in the voice bubble [noteId]'s dedicated
  /// [ChatMessage.transcription] field and clears its pending flag, leaving the
  /// audio clip, the (empty) bubble label, and everything else intact. The
  /// transcript is a HIDDEN, tap-to-reveal presentation concern — it is NOT
  /// written onto [ChatMessage.text]. What Axi consumes is the caller's
  /// `transcript` variable, unchanged. Returns the updated bubble so the caller
  /// can persist exactly what is shown, or null when the bubble is gone
  /// (history cleared mid-transcription).
  ChatMessage? _setVoiceTranscript(String noteId, String transcript) {
    ChatMessage? updated;
    final messages = state.messages.map((m) {
      if (m.id != noteId) return m;
      return updated =
          m.copyWith(transcription: transcript, transcriptionPending: false);
    }).toList();
    state = state.copyWith(messages: messages);
    return updated;
  }

  /// Triggers the on-device voice-model download (the "clear affordance" for a
  /// user who recorded a note before the ~80 MB model was fetched). Progress +
  /// status live in `sttModelDownloadProvider`. Best-effort; never throws.
  Future<void> downloadSttModel() =>
      ref.read(sttModelDownloadProvider.notifier).download();
}

/// One queued outgoing generation (a text turn or an image turn). Holds the
/// optimistic user message's [userMessageId] (so its delivery ticks can be
/// advanced), the [run] closure that performs the actual repository call, an
/// [errorPrefix] for a non-[ChatException] failure, and a [done] completer that
/// resolves when this request finishes — letting `sendMessage`/`sendImages`
/// return an awaitable future even though a shared [ChatNotifier._drain] loop
/// executes the work serially.
class _OutgoingRequest {
  _OutgoingRequest({
    required this.userMessageId,
    required this.run,
    required this.errorPrefix,
    this.onReply,
    this.userText,
  });

  final String userMessageId;

  /// Lo que escribió el usuario en ESTE turno, cuando lo hay.
  ///
  /// Sirve para una sola cosa: comprobar que la respuesta del modelo no sea el
  /// mensaje devuelto. Un turno de imagen no lo lleva — ahí no hay eco posible.
  final String? userText;
  final Future<ChatMessage> Function() run;
  final String errorPrefix;

  /// Optional hook run once THIS request's reply is appended (SLICE C1 memory
  /// write-back). Null for turns that should not be recorded (image turns, or
  /// when on-device mode is off). Text turns AND transcribed voice turns set it.
  final void Function(ChatMessage reply)? onReply;
  final Completer<void> done = Completer<void>();
}
