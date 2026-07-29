/// Where the user's own backup host lives, and the key that opens it.
///
/// This is NOT what protects the data — the archive is sealed with the user's
/// passphrase before it leaves the phone, so the key only stops strangers on
/// the same network from filling the store. Losing it is an inconvenience;
/// losing the passphrase is permanent.
class BackupHostConfig {
  const BackupHostConfig({required this.baseUrl, required this.accessKey});

  static const empty = BackupHostConfig(baseUrl: '', accessKey: '');

  /// e.g. `http://10.66.66.1:8099` — a private address, reached over the VPN.
  final String baseUrl;
  final String accessKey;

  bool get isComplete => baseUrl.trim().isNotEmpty && accessKey.trim().isNotEmpty;

  /// Joins [path] onto the base without producing `//`, which some proxies
  /// answer with a redirect and others with a 404.
  String endpoint(String path) {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final suffix = path.startsWith('/') ? path : '/$path';
    return '$base$suffix';
  }

  BackupHostConfig copyWith({String? baseUrl, String? accessKey}) =>
      BackupHostConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        accessKey: accessKey ?? this.accessKey,
      );

  @override
  bool operator ==(Object other) =>
      other is BackupHostConfig &&
      other.baseUrl == baseUrl &&
      other.accessKey == accessKey;

  @override
  int get hashCode => Object.hash(baseUrl, accessKey);
}
