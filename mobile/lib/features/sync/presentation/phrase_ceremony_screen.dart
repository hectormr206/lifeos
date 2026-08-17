import 'package:flutter/material.dart';

import '../domain/phrase_ceremony.dart';

/// The twelve words: show them, then prove they were written down.
///
/// This screen exists because there is no escrow, no copy on the server and no
/// reset link. If the paper is wrong, the data is gone the day the last device
/// is — and the user finds out at the worst possible moment.
///
/// Two deliberate frictions, both of which a well-meaning designer would remove:
///
///   * NO "copiar al portapapeles". A clipboard is read by every app on the
///     phone and survives in clipboard history. The point of paper is that it
///     is not on the phone.
///   * The confirmation asks for a RANDOM subset. Asking for all twelve makes
///     people abandon the flow (and abandoning means leaving sync off); asking
///     for a FIXED subset teaches everyone to copy only those positions.
///
/// The rules live in `PhraseCeremony` and are unit-tested; this screen only
/// presents them.
class PhraseCeremonyScreen extends StatefulWidget {
  const PhraseCeremonyScreen({
    super.key,
    required this.ceremony,
    required this.onConfirmed,
    required this.onCancel,
  });

  final PhraseCeremony ceremony;

  /// Called only once [PhraseCeremony.confirm] has returned true.
  final void Function(PhraseCeremony confirmed) onConfirmed;

  final VoidCallback onCancel;

  @override
  State<PhraseCeremonyScreen> createState() => _PhraseCeremonyScreenState();
}

class _PhraseCeremonyScreenState extends State<PhraseCeremonyScreen> {
  bool _showingWords = true;
  bool _failed = false;
  late final Map<int, TextEditingController> _answers = {
    for (final i in widget.ceremony.challengeIndices) i: TextEditingController(),
  };

  @override
  void dispose() {
    for (final c in _answers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _check() {
    final ok = widget.ceremony.confirm(
      {for (final e in _answers.entries) e.key: e.value.text},
    );
    if (ok) {
      widget.onConfirmed(widget.ceremony);
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_showingWords ? 'Tu frase de recuperación' : 'Confírmala'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: widget.onCancel,
        ),
      ),
      body: _showingWords
          ? _Words(
              ceremony: widget.ceremony,
              onNext: () => setState(() => _showingWords = false),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Escribe estas palabras de tu frase para confirmar que las '
                  'anotaste.',
                  style: text.bodyMedium,
                ),
                const SizedBox(height: 16),
                for (final i in widget.ceremony.challengeIndices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: _answers[i],
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Palabra ${i + 1}',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                if (_failed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Alguna palabra no coincide. Revisa tu papel y vuelve a '
                      'intentarlo.',
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                FilledButton(
                  onPressed: _check,
                  child: const Text('Confirmar y activar'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _showingWords = true;
                    _failed = false;
                  }),
                  child: const Text('Ver las palabras otra vez'),
                ),
              ],
            ),
    );
  }
}

class _Words extends StatelessWidget {
  const _Words({required this.ceremony, required this.onNext});

  final PhraseCeremony ceremony;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Escribe estas doce palabras en papel y guárdalas en un lugar seguro.',
          style: text.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Son la única forma de recuperar tu información si pierdes todos tus '
          'dispositivos. Nadie más las tiene: ni nosotros, ni el servidor. Si '
          'las pierdes, no hay manera de recuperarlas.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: 20),
        // A plain numbered grid. No copy button on purpose — see the class doc.
        for (var i = 0; i < ceremony.words.length; i++)
          ListTile(
            dense: true,
            leading: SizedBox(
              width: 28,
              child: Text('${i + 1}.', style: text.bodySmall),
            ),
            title: Text(
              ceremony.words[i],
              style: text.titleMedium?.copyWith(fontFeatures: null),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: onNext,
          child: const Text('Ya las anoté'),
        ),
      ],
    );
  }
}
