import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_lock_controller.dart';
import 'app_lock_providers.dart';
import 'lock_screen.dart';

/// Wraps the whole app (installed via `MaterialApp.router`'s `builder`) and
/// gates entry behind the optional biometric lock.
///
///  * [AppLockStatus.disabled] / [AppLockStatus.unlocked] → shows [child].
///  * [AppLockStatus.locked]   → shows the [LockScreen] over the content.
///
/// The initial state is resolved synchronously from the pre-frame flag (see
/// [AppLockController.build]), so there is no splash phase. The lock is
/// default-OFF, so for the vast majority of users this is a transparent
/// pass-through to [child].
class AppLockGate extends ConsumerWidget {
  const AppLockGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(appLockControllerProvider);
    return switch (status) {
      AppLockStatus.disabled || AppLockStatus.unlocked => child,
      AppLockStatus.locked => const LockScreen(),
    };
  }
}
