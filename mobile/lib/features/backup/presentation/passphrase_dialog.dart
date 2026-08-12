import 'package:flutter/material.dart';

/// Asks for the passphrase that seals (or opens) a backup.
///
/// When [confirm] is set the phrase must be typed twice. That is not
/// ceremony: the phrase is never stored anywhere, so a typo produces an
/// archive nobody can open — including the person who made it — and nothing
/// would reveal that until a restore is attempted, possibly months later.
/// Opening an existing archive needs no confirmation: a wrong phrase there
/// fails immediately and harmlessly.
class PassphraseDialog extends StatefulWidget {
  const PassphraseDialog({
    super.key,
    required this.title,
    required this.actionLabel,
    this.confirm = false,
  });

  final String title;
  final String actionLabel;
  final bool confirm;

  /// Returns the phrase, or null if the user backed out.
  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String actionLabel,
    bool confirm = false,
  }) =>
      showDialog<String>(
        context: context,
        builder: (_) => PassphraseDialog(
          title: title,
          actionLabel: actionLabel,
          confirm: confirm,
        ),
      );

  @override
  State<PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<PassphraseDialog> {
  final _phrase = TextEditingController();
  final _repeat = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _phrase.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _submit() {
    final phrase = _phrase.text;
    if (phrase.isEmpty) {
      setState(() => _error = 'Escribe una frase.');
      return;
    }
    if (widget.confirm && phrase != _repeat.text) {
      setState(() => _error = 'Las dos frases no coinciden.');
      return;
    }
    Navigator.of(context).pop(phrase);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.confirm)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Esta frase es lo único que abre el respaldo. No se guarda en '
                'ningún lado: si la olvidas, no hay forma de recuperarlo.',
              ),
            ),
          TextField(
            controller: _phrase,
            obscureText: _obscure,
            autofocus: true,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Frase de recuperación',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                // Revealing it matters here: a phrase typed blind into a field
                // that will never be recoverable is a trap.
                tooltip: _obscure ? 'Mostrar' : 'Ocultar',
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          if (widget.confirm) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _repeat,
              obscureText: _obscure,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Repetila',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.actionLabel)),
      ],
    );
  }
}
