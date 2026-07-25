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
/// The [child] (the whole Router subtree) stays MOUNTED underneath while
/// locked: a re-lock must never destroy navigation or in-progress screen state
/// (a half-typed chat draft, a recording, a scroll position) — unlocking
/// restores exactly where the user was. While locked the child is [Offstage]
/// (not painted, not hit-testable, no semantics) and excluded from focus, and
/// the [LockScreen] — an opaque full-screen Scaffold — is stacked on top, so
/// the protected content is neither visible nor interactable.
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
    final locked = status == AppLockStatus.locked;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        // Kept in the tree in BOTH states so the Router's element (and every
        // screen State under it) survives lock/unlock cycles.
        ExcludeFocus(
          excluding: locked,
          child: Offstage(offstage: locked, child: child),
        ),
        if (locked) const LockScreen(),
      ],
    );
  }
}
