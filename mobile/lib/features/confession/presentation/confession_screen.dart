// Desahogo: alguien que te escucha.
//
// Three properties hold this together, and the code is arranged so they are
// hard to break by accident. See `domain/confession.dart` for the reasoning.
//
//   1. NOTHING IS STORED. This file imports no store, no repository and no
//      graph — there is nowhere for the words to go. A test reads the source
//      and fails if that ever changes, because "we forgot to persist it" is
//      not a guarantee, and this is the one feature whose entire value rests
//      on the promise being literally true.
//   2. IT NEVER FORGIVES. That rule lives in the preamble, with its own tests
//      — and it stays OUT of the copy on screen. Opening with a list of what
//      this is not makes someone defend themselves before they have said
//      anything, and the person who most needs this is the least likely to
//      push past a paragraph of disclaimers.
//   3. IT ENDS, VISIBLY. The words fade out and the field is empty.
//
// And it takes VOICE as well as typing, because most of what people carry is
// easier said than written.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/data/chat_repository.dart';
import '../../dictation/domain/dictation_status.dart';
import '../../dictation/presentation/dictate_controller.dart';
import '../../local_model/data/on_device_chat_repository.dart';
import '../../local_model/presentation/local_model_providers.dart';
import '../domain/confession.dart';
import '../domain/confession_prompt.dart';

/// A chat repository with the Desahogo guidance and NO memory of the user.
///
/// Built here rather than reusing `chatRepositoryProvider` on purpose: that one
/// prefixes every turn with facts recalled from the graph, and something that
/// can quote your weight and your family back at you is not the stranger this
/// moment needs.
final confessionRepositoryProvider =
    Provider.family<ChatRepository, String>((ref, languageCode) {
  return OnDeviceChatRepository(
    ref.watch(localLlmEngineProvider),
    decoratePrompt: (message) =>
        buildConfessionPrompt(message, languageCode: languageCode),
  );
});

class ConfessionScreen extends ConsumerStatefulWidget {
  const ConfessionScreen({super.key});

  @override
  ConsumerState<ConfessionScreen> createState() => _ConfessionScreenState();
}

class _ConfessionScreenState extends ConsumerState<ConfessionScreen> {
  final _session = ConfessionSession();
  final _controller = TextEditingController();

  String? _reply;
  bool _thinking = false;

  /// Drives the fade. 1.0 is fully visible; the release animates it to 0.
  double _opacity = 1;

  @override
  void dispose() {
    // Leaving by the back button has to be as complete as finishing on
    // purpose, or the promise depends on which way you left.
    _session.release();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _say() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _session.write(text);
    final language = Localizations.localeOf(context).languageCode;

    // Checked in DART, before the model sees a word. Someone saying they
    // intend to end their life must not depend on a small model choosing to
    // notice — the one case where reflecting the feeling back is the wrong
    // answer, and the one where getting it wrong is unrecoverable.
    final safety = confessionSafetyNote(text, languageCode: language);
    // Said out loud, never silent: a reply about the last few minutes would
    // otherwise read as a verdict on everything.
    final trimmedNote = wasTrimmedForDesahogo(text)
        ? (language == 'en'
            ? 'I read the last part of what you said.'
            : 'Me quedé con la última parte de lo que dijiste.')
        : null;

    setState(() => _thinking = true);
    String answer;
    try {
      final result = await ref
          .read(confessionRepositoryProvider(language))
          .sendMessage(trimForDesahogo(text));
      answer = result.text.trim();
      // An empty or degenerate generation is not an answer. Falling through to
      // the written close is better than handing someone a blank.
      if (answer.length < 12) {
        answer = desahogoFallbackReply(languageCode: language);
      }
    } catch (_) {
      // NEVER an error message here. Someone has just said the thing they do
      // not say out loud; "no pude responderte" is a door shutting in their
      // face.
      answer = desahogoFallbackReply(languageCode: language);
    }
    if (!mounted) return;
    setState(() {
      _reply = [
        if (safety != null) safety,
        if (trimmedNote != null) trimmedNote,
        answer,
      ].join('\n\n');
      _thinking = false;
    });
  }

  Future<void> _release() async {
    setState(() => _opacity = 0);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    _session.release();
    _controller.clear();
    setState(() {
      _reply = null;
      _opacity = 1;
    });
  }

  /// Tap to start, tap again to stop. The recording is NEVER cut short by a
  /// timer: "hasta que se desahogue" is the whole point, and a countdown while
  /// someone is crying is the opposite of this screen. Only what reaches the
  /// model is trimmed, and that is said out loud.
  Future<void> _toggleMic(DictationStatus status) async {
    final controller = ref.read(dictateControllerProvider.notifier);
    if (status is DictationRecording) {
      await controller.stop();
    } else {
      await controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;
    final text = Theme.of(context).textTheme;
    final dictation = ref.watch(dictateControllerProvider);

    // A finished take goes straight into the box, appended rather than
    // replacing: someone may have typed a line and then decided to talk.
    ref.listen<DictationStatus>(dictateControllerProvider, (_, next) {
      if (next is! DictationReady) return;
      final existing = _controller.text.trim();
      _controller.text =
          existing.isEmpty ? next.text : '$existing\n${next.text}';
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Desahogo')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // What this is FOR, before anything is typed. It leads with the
              // one thing it offers — someone listening — and keeps the single
              // promise a person needs before they start: where the words go.
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Alguien que te escucha', style: text.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        'Dilo con todas sus palabras: eso que traes cargando y '
                        'que no le has contado a nadie. Escríbelo o cuéntalo '
                        'en voz alta, todo el tiempo que necesites. Axi te va '
                        'a escuchar y a responder, y después lo sueltas.',
                        style: text.bodyMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Nada de esto se guarda: ni en este dispositivo, ni en '
                        'los otros, ni en el servidor. No entra en tu memoria '
                        'de LifeOS ni aparece en el Cerebro. Cuando lo sueltes, '
                        'desaparece.',
                        style: text.bodySmall
                            ?.copyWith(color: Theme.of(context).hintColor),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              AnimatedOpacity(
                opacity: _opacity,
                duration: const Duration(milliseconds: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _controller,
                      minLines: 5,
                      maxLines: 12,
                      decoration: const InputDecoration(
                        hintText: 'Aquí, con tus palabras…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_reply != null) ...[
                      const SizedBox(height: 16),
                      Card(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(_reply!, style: text.bodyLarge),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (_thinking)
                const Center(child: CircularProgressIndicator())
              else if (_reply == null) ...[
                _MicRow(status: dictation, onTap: () => _toggleMic(dictation)),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.hearing),
                  label: const Text('Decirlo'),
                  onPressed: _say,
                ),
              ] else
                Column(
                  children: [
                    Text(
                      confessionClosing(languageCode: language),
                      textAlign: TextAlign.center,
                      style: text.bodySmall
                          ?.copyWith(color: Theme.of(context).hintColor),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Soltarlo'),
                      onPressed: _release,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The microphone, with whatever it is doing said in words.
///
/// No timer and no countdown: the recording runs until the user stops it.
class _MicRow extends StatelessWidget {
  const _MicRow({required this.status, required this.onTap});

  final DictationStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final recording = status is DictationRecording;
    final transcribing = status is DictationTranscribing;
    final failed = status is DictationFailed;

    return Column(
      children: [
        OutlinedButton.icon(
          icon: Icon(recording ? Icons.stop_circle_outlined : Icons.mic_none),
          label: Text(recording ? 'Terminar de hablar' : 'Contarlo hablando'),
          onPressed: transcribing ? null : onTap,
        ),
        if (recording)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Te escucho. Tómate el tiempo que necesites.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (transcribing)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Poniéndolo en palabras…'),
          ),
        if (failed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              // The one place an error belongs: the mic did not work, and the
              // person has not said anything yet. Escribirlo sigue disponible.
              '${(status as DictationFailed).message}\n'
              'Puedes escribirlo aquí abajo.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}
