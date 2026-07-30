import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where ratchet state is kept between launches.
///
/// This state is live key material: it derives every future message key for a
/// conversation. It belongs in the platform keystore for exactly the reasons
/// identity keys do, and never in `SharedPreferences`.
abstract class RatchetStore {
  Future<String?> read(String peerKexPublicKey);
  Future<void> write(String peerKexPublicKey, String stateJson);
  Future<void> delete(String peerKexPublicKey);

  /// Removes every session. Used by the factory reset.
  Future<void> deleteAll();
}

/// Keystore-backed store, keyed by a digest of the peer's agreement key.
///
/// The key is hashed rather than used directly because a base64 X25519 key
/// contains `/` and `+`, and keystore backends are not uniformly happy with
/// those in an item name.
class SecureRatchetStore implements RatchetStore {
  static const _prefix = 'c2_ratchet_v3_';
  static const _indexKey = 'c2_ratchet_v3_index';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  /// Serializes access so two concurrent messages to the same peer cannot
  /// interleave a read-modify-write and lose a chain step.
  Future<void> _tail = Future.value();

  static String _entryKey(String peerKexPublicKey) {
    final digest = hashing.sha256.convert(utf8.encode(peerKexPublicKey));
    return '$_prefix${digest.toString().substring(0, 32)}';
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  @override
  Future<String?> read(String peerKexPublicKey) =>
      _serialized(() => _storage.read(key: _entryKey(peerKexPublicKey)));

  @override
  Future<void> write(String peerKexPublicKey, String stateJson) =>
      _serialized(() async {
        final key = _entryKey(peerKexPublicKey);
        await _storage.write(key: key, value: stateJson);
        await _addToIndex(key);
      });

  @override
  Future<void> delete(String peerKexPublicKey) => _serialized(() async {
        final key = _entryKey(peerKexPublicKey);
        await _storage.delete(key: key);
        await _removeFromIndex(key);
      });

  @override
  Future<void> deleteAll() => _serialized(() async {
        for (final key in await _readIndex()) {
          await _storage.delete(key: key);
        }
        await _storage.delete(key: _indexKey);
      });

  // An explicit index rather than readAll(), which would return every item the
  // app has stored and force this to guess which ones are ratchet state.
  Future<Set<String>> _readIndex() async {
    final raw = await _storage.read(key: _indexKey);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<String>().toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> _addToIndex(String key) async {
    final index = await _readIndex();
    if (index.add(key)) {
      await _storage.write(key: _indexKey, value: jsonEncode(index.toList()));
    }
  }

  Future<void> _removeFromIndex(String key) async {
    final index = await _readIndex();
    if (index.remove(key)) {
      await _storage.write(key: _indexKey, value: jsonEncode(index.toList()));
    }
  }
}

/// Non-persistent store.
///
/// For tests, and for the live-relay suite, which deliberately runs without a
/// platform keychain. Sessions do not survive a restart, which for a test
/// process is the point.
@visibleForTesting
class InMemoryRatchetStore implements RatchetStore {
  final Map<String, String> _entries = {};

  int get sessionCount => _entries.length;

  @override
  Future<String?> read(String peerKexPublicKey) async => _entries[peerKexPublicKey];

  @override
  Future<void> write(String peerKexPublicKey, String stateJson) async {
    _entries[peerKexPublicKey] = stateJson;
  }

  @override
  Future<void> delete(String peerKexPublicKey) async {
    _entries.remove(peerKexPublicKey);
  }

  @override
  Future<void> deleteAll() async => _entries.clear();
}
