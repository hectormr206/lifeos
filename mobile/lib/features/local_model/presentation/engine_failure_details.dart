import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/engine_failure_detail.dart';

/// The collapsed "technical details" affordance under a model-failure message.
///
/// WHY IT IS COLLAPSED, AND WHY IT EXISTS AT ALL. The plain-language sentence
/// above it is the headline and stays the headline: it is the part the user can
/// act on, and burying it under a stack trace would be a regression. But that
/// sentence used to be the END of the evidence — the real exception died in a
/// `catch (_)`. On the device where these failures actually happen there is no
/// way to recover it afterwards: the test suite has no plugin channel, a
/// terminal app's logcat shows only its own logs, and there may be no second
/// device to reproduce on. So the exception is kept, one tap away, and
/// copyable — the user can read it and quote it back.
///
/// Deliberately NOT translated: this is the runtime's own text, and altering it
/// would damage the only evidence there is.
class EngineFailureDetails extends StatefulWidget {
  const EngineFailureDetails({super.key, required this.detail});

  final EngineFailureDetail detail;

  @override
  State<EngineFailureDetails> createState() => _EngineFailureDetailsState();
}

class _EngineFailureDetailsState extends State<EngineFailureDetails> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: theme.hintColor,
                ),
                const SizedBox(width: 4),
                Text(
                  _expanded ? l10n.engineErrorDetailsHide : l10n.engineErrorDetailsShow,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            // Selectable as well as copyable: quoting one line of a long native
            // message is a normal thing to want.
            child: SelectableText(
              widget.detail.text,
              style: theme.textTheme.labelSmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _copy(context, l10n),
              icon: const Icon(Icons.copy_all_outlined, size: 16),
              label: Text(l10n.engineErrorDetailsCopy),
            ),
          ),
        ],
      ],
    );
  }

  /// Copies the whole detail and CONFIRMS it — including when the clipboard
  /// itself refused, because a copy button that silently does nothing is the
  /// same dead-tap problem this widget exists to fix.
  Future<void> _copy(BuildContext context, AppLocalizations l10n) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: widget.detail.text));
      messenger.showSnackBar(SnackBar(content: Text(l10n.engineErrorDetailsCopied)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.engineErrorDetailsFailed)));
    }
  }
}
