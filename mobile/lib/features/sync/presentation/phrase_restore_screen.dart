// "Ya tengo una frase": joining a device set that already exists.
//
// The counterpart to `PhraseCeremonyScreen`. That screen CREATES a key for the
// first device; this one ADOPTS the key every other device already shares.
// Without it there is no second device — only a second, unrelated key, and two
// installs that both report "sincronización activa" while never exchanging a
// single row.
//
// The checksum does the deciding. `decodePhrase` validates it and throws before
// anything is stored, so a mistyped word leaves the device exactly as it was:
// no half-written key material, no partially-enabled state.
//
// No "pegar desde el portapapeles", for the same reason the ceremony has no
// copy button: the clipboard is readable by every app on the device and
// survives in clipboard history. The phrase belongs on paper.
import 'package:flutter/material.dart';

import 'package:lifeos/core/sync/phrase.dart';

class PhraseRestoreScreen extends StatefulWidget {
  const PhraseRestoreScreen({
    super.key,
    required this.onRestore,
    required this.onCancel,
  });

  /// Called ONLY with a phrase whose checksum already passed. The callback
  /// stores it; validating here means the caller cannot forget to.
  final Future<void> Function(String mnemonic) onRestore;

  final VoidCallback onCancel;

  @override
  State<PhraseRestoreScreen> createState() => _PhraseRestoreScreenState();
}

class _PhraseRestoreScreenState extends State<PhraseRestoreScreen> {
  final _controller = TextEditingController();
  bool _rejected = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Sanitised before validating AND before storing, so the commas and stray
    // period a keyboard adds never make a correct phrase look invalid.
    final typed = sanitiseTypedPhrase(_controller.text);
    try {
      // Decoded purely to check the phrase; the entropy is deliberately
      // discarded so this screen never holds key material it does not store.
      decodePhrase(typed);
    } catch (_) {
      setState(() => _rejected = true);
      return;
    }
    setState(() => _rejected = false);
    await widget.onRestore(typed);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Usar mi frase'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: widget.onCancel,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Escribe las doce palabras de tu otro dispositivo.',
            style: text.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Tiene que ser la misma frase. Es lo que hace que los dos '
            'dispositivos compartan la misma información: con una frase '
            'distinta, cada uno queda por su cuenta.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _controller,
            // Autocorrect would "fix" words the checksum then rejects, and the
            // user would be left correcting a phrase they typed right.
            autocorrect: false,
            enableSuggestions: false,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Tus doce palabras, separadas por espacios',
              border: OutlineInputBorder(),
            ),
          ),
          if (_rejected)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Esa frase no es válida. Revisa que estén las doce palabras y '
                'que no haya ninguna cambiada.',
                style: TextStyle(color: scheme.error),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _submit,
            child: const Text('Activar sincronización'),
          ),
        ],
      ),
    );
  }
}
