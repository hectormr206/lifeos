// The confession space.
//
// Three properties hold this together, and the code is arranged so they are
// hard to break by accident. See `domain/confession.dart` for the reasoning.
//
//   1. NOTHING IS STORED. This file imports no store, no repository and no
//      graph — there is nowhere for the words to go. A test reads the source
//      and fails if that ever changes, because "we forgot to persist it" is
//      not a guarantee, and this is the one feature whose entire value rests
//      on the promise being literally true.
//   2. IT NEVER FORGIVES. That rule lives in the preamble, with its own tests.
//   3. IT ENDS, VISIBLY. The words fade out and the field is empty. The
//      closing is the part of the practice that does the work.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/data/chat_repository.dart';
import '../../local_model/data/on_device_chat_repository.dart';
import '../../local_model/presentation/local_model_providers.dart';
import '../domain/confession.dart';
import '../domain/confession_prompt.dart';

/// A chat repository with the confession preamble and NO memory of the user.
///
/// Built here rather than reusing `chatRepositoryProvider` on purpose: that one
/// prefixes every turn with facts recalled from the graph, and a confession
/// annotated with your weight and your family is not what anyone is asking for.
final confessionRepositoryProvider = Provider.family<ChatRepository, String>((
  ref,
  languageCode,
) {
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
    // intend to end their life must not depend on a ~2B model choosing to
    // notice — the one case where reflecting the feeling back is the wrong
    // answer, and the one where getting it wrong is unrecoverable.
    final safety = confessionSafetyNote(text, languageCode: language);
    setState(() => _thinking = true);
    try {
      final answer = await ref
          .read(confessionRepositoryProvider(language))
          .sendMessage(text);
      if (!mounted) return;
      setState(() {
        // The safety line goes FIRST and is never replaced by the model's
        // words, only followed by them.
        _reply = safety == null ? answer.text : '$safety\n\n${answer.text}';
        _thinking = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Says what happened. A confession swallowed in silence is worse than
      // one that could not be answered.
      setState(() {
        _reply =
            'No pude responderte ahora mismo. Lo que escribiste sigue '
            'siendo tuyo y no se guardó en ninguna parte.';
        _thinking = false;
      });
    }
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

  @override
  Widget build(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      // Named for what it is FOR. "Confesión" promises a sacrament this
      // cannot give, and would shut the door on someone with no religion.
      appBar: AppBar(title: const Text('Desahogo')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // What this is, before anything is typed. Someone opening this
              // screen for the first time has to know what happens to what
              // they write BEFORE they write it.
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Un lugar para decirlo y soltarlo',
                        style: text.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Escribe eso que traes cargando. Axi te va a '
                        'responder, y después lo sueltas: el texto se borra '
                        'y no se guarda en ninguna parte — ni aquí, ni en '
                        'tus otros dispositivos, ni en el servidor. No queda '
                        'en tu memoria de LifeOS y no aparece en el Cerebro.',
                        style: text.bodyMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'No es una confesión religiosa: Axi no perdona ni '
                        'absuelve, porque no le corresponde. Sirve para lo '
                        'otro, que es la mitad que sí ayuda: decirlo con '
                        'todas sus palabras y que alguien lo escuche.',
                        style: text.bodySmall?.copyWith(
                          color: Theme.of(context).hintColor,
                        ),
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
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
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
              else if (_reply == null)
                FilledButton.icon(
                  icon: const Icon(Icons.hearing),
                  label: const Text('Decirlo'),
                  onPressed: _say,
                )
              else
                Column(
                  children: [
                    Text(
                      confessionClosing(languageCode: language),
                      textAlign: TextAlign.center,
                      style: text.bodySmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
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
