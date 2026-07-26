import '../../security/presentation/app_lock_controller.dart';

/// Owns the one-shot lifecycle from an Android assistant activation to Chat.
///
/// The controller is deliberately UI-free: app.dart supplies navigation and
/// route observation, while Chat claims the head request only after it is
/// mounted and has rechecked eligibility. Terminal IDs are never replayed.
class AssistantHandoffController {
  AssistantHandoffController({
    required void Function() navigateToChat,
    required bool Function() isCurrentChatRoute,
  })  : _navigateToChat = navigateToChat,
        _isCurrentChatRoute = isCurrentChatRoute;

  void Function() _navigateToChat;
  bool Function() _isCurrentChatRoute;
  final List<String> _pending = <String>[];
  final Set<String> _acknowledged = <String>{};
  final Set<String> _discarded = <String>{};
  AppLockStatus? _lock;
  bool _routing = false;
  bool _disposed = false;

  List<String> get pendingIds => List<String>.unmodifiable(_pending);
  Set<String> get acknowledgedIds => Set<String>.unmodifiable(_acknowledged);
  Set<String> get discardedIds => Set<String>.unmodifiable(_discarded);

  void bind({required void Function() navigateToChat, required bool Function() isCurrentChatRoute}) {
    if (_disposed) return;
    _navigateToChat = navigateToChat;
    _isCurrentChatRoute = isCurrentChatRoute;
    _advance();
  }

  void receive(String id) {
    if (_disposed || id.isEmpty || _isTerminal(id) || _pending.contains(id)) return;
    _pending.add(id);
    _advance();
  }

  void updateLock(AppLockStatus status) {
    if (_disposed) return;
    _lock = status;
    _advance();
  }

  /// Called after the `/chat` navigation has had a chance to settle.
  void onRouteSettled() {
    if (_disposed || !_routing || _pending.isEmpty) return;
    _routing = false;
    if (!_isCurrentChatRoute()) {
      discardCurrent();
    }
  }

  /// Atomically consumes the active request only from the currently mounted,
  /// eligible Chat screen. The acknowledgement is recorded before mic startup,
  /// so permission denial never makes the Android activation replayable.
  void claimMountedChat({required bool eligible, required void Function() armMicrophone}) {
    if (_disposed || _pending.isEmpty || _routing || !_isUnlocked) return;
    if (!_isCurrentChatRoute() || !eligible) {
      discardCurrent();
      return;
    }
    final id = _pending.removeAt(0);
    _acknowledged.add(id);
    armMicrophone();
    _advance();
  }

  /// Authentication denial/cancellation, disposal, route failure, or redirect
  /// is terminal. A later unlock or duplicate platform delivery cannot revive it.
  void discardCurrent() {
    if (_pending.isEmpty) return;
    _routing = false;
    _discarded.add(_pending.removeAt(0));
    _advance();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _discarded.addAll(_pending);
    _pending.clear();
    _routing = false;
  }

  // An activation observed before the lock provider reports its initial state
  // must wait. Treating the unknown state as unlocked would navigate before
  // AppLockGate has become authoritative.
  bool get _isUnlocked => _lock == AppLockStatus.disabled || _lock == AppLockStatus.unlocked;

  bool _isTerminal(String id) => _acknowledged.contains(id) || _discarded.contains(id);

  void _advance() {
    if (_disposed || _pending.isEmpty || !_isUnlocked || _routing) return;
    _routing = true;
    _navigateToChat();
  }
}
