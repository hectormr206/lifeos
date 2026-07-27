import '../../security/presentation/app_lock_controller.dart';
import '../domain/assistant_gateway.dart';

/// Owns the one-shot lifecycle from an Android assistant activation to Chat.
///
/// The controller is deliberately UI-free: app.dart supplies navigation and
/// route observation, while Chat claims the head request only after it is
/// mounted and has rechecked eligibility. Terminal IDs are never replayed.
class AssistantHandoffController {
  AssistantHandoffController({
    required void Function() navigateToChat,
    required bool Function() isCurrentChatRoute,
  }) : this._(navigateToChat, isCurrentChatRoute);

  AssistantHandoffController._(this._navigateToChat, this._isCurrentChatRoute);

  void Function() _navigateToChat;
  bool Function() _isCurrentChatRoute;
  void Function(String, AssistantTerminalOutcome) _terminalize = (_, _) {};
  final List<String> _pending = <String>[];
  final Set<String> _acknowledged = <String>{};
  final Set<String> _discarded = <String>{};
  AppLockStatus? _lock;
  bool? _mountedEligible;
  bool _routing = false;
  bool _disposed = false;

  List<String> get pendingIds => List<String>.unmodifiable(_pending);
  Set<String> get acknowledgedIds => Set<String>.unmodifiable(_acknowledged);
  Set<String> get discardedIds => Set<String>.unmodifiable(_discarded);

  void bind({
    required void Function() navigateToChat,
    required bool Function() isCurrentChatRoute,
    void Function(String, AssistantTerminalOutcome)? terminalize,
  }) {
    if (_disposed) return;
    _navigateToChat = navigateToChat;
    _isCurrentChatRoute = isCurrentChatRoute;
    if (terminalize != null) _terminalize = terminalize;
    _advance();
  }

  void receive(String id) {
    if (_disposed || id.isEmpty || _pending.contains(id)) return;
    if (_acknowledged.contains(id)) {
      _terminalize(id, AssistantTerminalOutcome.acknowledged);
      return;
    }
    if (_discarded.contains(id)) {
      _terminalize(id, AssistantTerminalOutcome.discarded);
      return;
    }
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

  /// Resolves every queued activation from mounted, eligible Chat. Assistant
  /// navigation never arms audio; recording remains an explicit Chat gesture.
  void claimMountedChat({required bool eligible}) {
    _mountedEligible = eligible;
    if (_disposed || _pending.isEmpty || _routing || !_isUnlocked) return;
    if (!_isCurrentChatRoute() || !eligible) {
      discardCurrent();
      return;
    }
    while (_pending.isNotEmpty) {
      final id = _pending.removeAt(0);
      _acknowledged.add(id);
      _terminalize(id, AssistantTerminalOutcome.acknowledged);
    }
    _advance();
  }

  void unclaimMountedChat() => _mountedEligible = null;

  /// Authentication denial/cancellation, disposal, route failure, or redirect
  /// is terminal. A later unlock or duplicate platform delivery cannot revive it.
  void discardCurrent() {
    if (_pending.isEmpty) return;
    _routing = false;
    final id = _pending.removeAt(0);
    _discarded.add(id);
    _terminalize(id, AssistantTerminalOutcome.discarded);
    _advance();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final id in _pending) {
      _discarded.add(id);
      _terminalize(id, AssistantTerminalOutcome.discarded);
    }
    _pending.clear();
    _routing = false;
  }

  // An activation observed before the lock provider reports its initial state
  // must wait. Treating the unknown state as unlocked would navigate before
  // AppLockGate has become authoritative.
  bool get _isUnlocked => _lock == AppLockStatus.disabled || _lock == AppLockStatus.unlocked;

  void _advance() {
    if (_disposed || _pending.isEmpty || !_isUnlocked || _routing) return;
    if (_isCurrentChatRoute()) {
      if (_mountedEligible != null) claimMountedChat(eligible: _mountedEligible!);
      return;
    }
    _routing = true;
    _navigateToChat();
  }
}
