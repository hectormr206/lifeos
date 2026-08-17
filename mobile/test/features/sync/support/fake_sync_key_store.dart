// An in-memory stand-in for the OS keystore.
//
// Records every value ever written, so a test can prove the mnemonic itself
// never reaches storage — the assertion that matters most here, and one a
// simple read-back fake cannot make.
import 'package:lifeos/features/sync/data/sync_key_store.dart';

class FakeSyncKeyStore implements SyncKeyStore {
  final Map<String, String> _values = {};

  /// Every string ever handed to the store, including values later deleted.
  final List<String> everythingWritten = [];

  int readCount = 0;

  @override
  Future<List<int>?> readEntropy() async {
    readCount++;
    final hex = _values['entropy'];
    if (hex == null) return null;
    return [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }

  @override
  Future<void> writeEntropy(List<int> entropy) async {
    final hex =
        entropy.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    everythingWritten.add(hex);
    _values['entropy'] = hex;
  }

  @override
  Future<void> clear() async {
    _values.remove('entropy');
  }
}
