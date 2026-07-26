import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../security/encrypted_file_cipher.dart';

/// Offline read cache abstraction (M3 slice 1: "losing the phone must never
/// mean losing your life"). Repositories write-through the last successful
/// engine response here and read-through it when the network fails, so the
/// app can still show the user's last-known data offline.
///
/// Deliberately pure-Dart and dead simple — no native DB deps (no
/// drift/sqflite/build_runner) for this slice, per design.
abstract class ResponseCache {
  /// Stores [json] (a JSON-encodable value: `Map`, `List`, or primitive)
  /// under [key], stamped with the current time as its fetch time.
  Future<void> put(String key, Object json);

  /// Returns the last value stored under [key], or `null` if never stored
  /// (or unreadable — a corrupt cache entry is treated as a miss, never an
  /// error).
  Future<Object?> get(String key);

  /// Returns when the value under [key] was last stored via [put], or
  /// `null` if there is no (readable) entry.
  Future<DateTime?> fetchedAt(String key);
}

/// Simple in-memory [ResponseCache]. Used by tests/fakes, and as the
/// fallback default for repositories constructed without an explicit cache.
class InMemoryResponseCache implements ResponseCache {
  final Map<String, _CacheEntry> _store = {};

  @override
  Future<void> put(String key, Object json) async {
    _store[key] = _CacheEntry(fetchedAt: DateTime.now(), body: json);
  }

  @override
  Future<Object?> get(String key) async => _store[key]?.body;

  @override
  Future<DateTime?> fetchedAt(String key) async => _store[key]?.fetchedAt;
}

class _CacheEntry {
  const _CacheEntry({required this.fetchedAt, required this.body});

  final DateTime fetchedAt;
  final Object body;
}

/// File-backed [ResponseCache] used in production: one JSON file per key
/// under the app support directory, `{"fetchedAt": <iso8601>, "body": <json>}`.
///
/// Takes an injectable [directoryProvider] (defaults to
/// `path_provider`'s `getApplicationSupportDirectory`) so this stays testable
/// without a platform channel — tests inject a plain temp `Directory`.
class FileResponseCache implements ResponseCache {
  FileResponseCache({
    Future<Directory> Function()? directoryProvider,
    EncryptedFileCipher? cipher,
  }) : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory,
       _cipher = cipher ?? EncryptedFileCipher();

  final Future<Directory> Function() _directoryProvider;
  final EncryptedFileCipher _cipher;

  static const _subdir = 'response_cache';

  @override
  Future<void> put(String key, Object json) async {
    final file = await _fileFor(key);
    final entry = <String, Object?>{
      'fetchedAt': DateTime.now().toIso8601String(),
      'body': json,
    };
    await _cipher.writeSealed(file, utf8.encode(jsonEncode(entry)));
  }

  @override
  Future<Object?> get(String key) async {
    final entry = await _readEntry(key);
    return entry?['body'];
  }

  @override
  Future<DateTime?> fetchedAt(String key) async {
    final entry = await _readEntry(key);
    final raw = entry?['fetchedAt'];
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }

  /// Reads and decodes the entry for [key]. Any failure (missing file,
  /// malformed JSON, unexpected shape) degrades to `null` — a corrupt cache
  /// file must never crash the app, it is simply treated as a cache miss.
  Future<Map<String, Object?>?> _readEntry(String key) async {
    try {
      final file = await _fileFor(key);
      if (!await file.exists()) return null;
      final raw = await file.readAsBytes();
      final plaintext = await _cipher.openOrLegacy(raw);
      if (plaintext == null) return null;
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is Map) {
        // One-shot, read-through migration for builds that wrote plaintext.
        if (!_cipher.isEncrypted(raw)) {
          await _cipher.writeSealed(file, plaintext);
        }
        return Map<String, Object?>.from(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<File> _fileFor(String key) async {
    final root = await _directoryProvider();
    final dir = Directory('${root.path}/$_subdir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/${_sanitize(key)}.json');
  }

  /// Cache keys use `:` as a namespace separator (e.g.
  /// `"domains:health:entries"`), which is unsafe/inconsistent across
  /// filesystems — replaced with `_` for the on-disk filename.
  String _sanitize(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
}

/// The active [ResponseCache] used app-wide: file-backed in prod so the
/// last-known data survives a process restart, overridden with
/// [InMemoryResponseCache] in tests (same pattern as [tokenStoreProvider] in
/// `core/api/api_providers.dart`).
final responseCacheProvider = Provider<ResponseCache>(
  (ref) => FileResponseCache(),
);
