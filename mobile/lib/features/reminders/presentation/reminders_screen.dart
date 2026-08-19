// TODO(i18n): hardcoded neutral Spanish pending the i18n sweep (this screen
// predates the ARB slice and was never localized).
import 'package:flutter/material.dart';

import 'local_reminders_tab.dart';

/// Reminders, on THIS device.
///
/// There used to be a second tab, "Desde el motor Axi": a viewer for reminders
/// living on a paired server. That design is gone. The plan was to run a
/// bigger model on a powerful machine and share it with everything else;
/// today every device runs its own local model and syncs the results, so
/// there is nothing on the other side of that tab. All it could do was show
/// "No se pudo conectar con Axi. Revisa tu conexión" — sending someone to
/// check a Wi-Fi that was never the problem.
///
/// Reminders reach the other devices the same way everything else does: the
/// graph syncs, and each device schedules its own notification from the same
/// row.
class RemindersScreen extends StatelessWidget {
  const RemindersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recordatorios')),
      body: const LocalRemindersTab(),
    );
  }
}
