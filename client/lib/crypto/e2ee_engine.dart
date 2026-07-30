import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter/foundation.dart';

import 'double_ratchet.dart';
import 'operator_identity.dart';
import 'ratchet_store.dart';

/// Raised when a ciphertext fails authentication, is malformed, or replays a
/// nonce we have already accepted. Callers must treat this as hostile input,
/// not as a display string.
class DecryptionFailure implements Exception {
  final String reason;
  const DecryptionFailure(this.reason);
  @override
  String toString() => 'DecryptionFailure: $reason';
}

/// E2EEEngine provides authenticated pairwise encryption between two operators.
///
/// Sealing runs through a [DoubleRatchetSession]: an alternating Diffie-Hellman
/// ratchet over per-message symmetric chains, established from the two static
/// X25519 identities exchanged at pairing. Each message gets its own key, which
/// is destroyed after use, so a device compromised today does not decrypt
/// traffic captured yesterday — and because each DH step mixes in a freshly
/// generated key, an adversary who steals session state loses it again after one
/// round trip. AES-256-GCM with a random 96-bit nonce does the encryption; the
/// envelope header and the ratchet header are both bound in as additional
/// authenticated data, so a relay cannot move a message between conversations
/// or rewrite its metadata undetected.
///
/// The nonce stays random even though each message key is used exactly once and
/// a fixed nonce would be sound. It is cheap insurance: if ratchet state were
/// ever lost and a chain position reused, a random nonce keeps that from
/// becoming catastrophic GCM nonce-and-key reuse.
///
/// Version 2 ciphertexts — static-static agreement, no forward secrecy — are
/// still *accepted* so a peer that has not yet updated keeps working, and their
/// arrival is reported. Nothing is ever sent as v2.
class E2EEEngine {
  static const _legacyKeyInfo = 'vector-c2/pairwise/v2';
  static final _aead = AesGcm.with256bits();

  final OperatorIdentity identity;

  /// Where ratchet state is persisted. Defaults to the platform keystore.
  final RatchetStore store;

  final Map<String, DoubleRatchetSession> _sessions = {};

  /// Serializes work per peer. Two messages sealed concurrently for the same
  /// contact would otherwise interleave their chain steps and could derive the
  /// same message key twice.
  final Map<String, Future<void>> _peerLocks = {};

  /// Cache of legacy v2 keys, for inbound traffic from a peer still on v2.
  final Map<String, SecretKey> _legacySessionKeys = {};

  /// Nonces already accepted per peer on the v2 path. The ratchet needs no such
  /// list — a v3 message key is deleted on use, so a replay has no key left.
  final Map<String, Set<String>> _legacySeenNonces = {};

  /// Reports receipt of a v2 ciphertext, which has no forward secrecy. Lets the
  /// app tell an operator that a contact is on an older build.
  void Function(String remoteKexPublicKey)? onLegacyCiphertext;

  E2EEEngine({required this.identity, RatchetStore? store})
      : store = store ?? SecureRatchetStore();

  /// Runs [action] with exclusive access to one peer's session.
  Future<T> _withPeer<T>(String peerKey, Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _peerLocks[peerKey] ?? Future<void>.value();

    _peerLocks[peerKey] = previous.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });

    return completer.future;
  }

  /// Loads or establishes the session for [remoteKexPublicKey].
  Future<DoubleRatchetSession> _session(String remoteKexPublicKey) async {
    final cached = _sessions[remoteKexPublicKey];
    if (cached != null) return cached;

    // A read failure here is not the "secure storage is unavailable" case that
    // is fatal by design — that is settled at startup, where the identity keys
    // are loaded and the app refuses to run without a keystore. Reaching this
    // point means the keystore worked minutes ago, so a failure now is
    // transient. Losing session resumption beats refusing to send: the fallback
    // is an in-memory session, never unprotected storage.
    String? persisted;
    try {
      persisted = await store.read(remoteKexPublicKey);
    } catch (e) {
      debugPrint('[E2EE] Could not read ratchet state, continuing in memory: $e');
    }

    if (persisted != null) {
      try {
        final restored = await DoubleRatchetSession.fromJson(
          jsonDecode(persisted) as Map<String, dynamic>,
        );
        _sessions[remoteKexPublicKey] = restored;
        return restored;
      } catch (e) {
        // Unreadable state would otherwise wedge the conversation forever. Both
        // sides re-establish deterministically from their static keys, so
        // starting over costs at most the messages already in flight.
        debugPrint('[E2EE] Discarding unusable ratchet state: $e');
        try {
          await store.delete(remoteKexPublicKey);
        } catch (_) {}
      }
    }

    final fresh = await DoubleRatchetSession.establish(
      selfAgreementKeyPair: identity.agreementKeyPair,
      selfKexPublicKey: identity.kexPublicKey,
      remoteKexPublicKey: remoteKexPublicKey,
    );
    _sessions[remoteKexPublicKey] = fresh;
    await _persist(remoteKexPublicKey, fresh);
    return fresh;
  }

  Future<void> _persist(String peerKey, DoubleRatchetSession session) async {
    try {
      await store.write(peerKey, jsonEncode(await session.toJson()));
    } catch (e) {
      // A failed write means the session cannot be resumed after a restart. It
      // does not invalidate the in-memory session, so the current conversation
      // continues rather than dropping messages on the floor.
      debugPrint('[E2EE] Failed to persist ratchet state: $e');
    }
  }

  /// Drops all key material for a peer. Call on unpair.
  ///
  /// Deliberately also clears persisted state: leaving it behind would let a
  /// re-pair resume a session whose chain position the other side has forgotten.
  Future<void> forgetPeer(String remoteKexPublicKey) async {
    _sessions.remove(remoteKexPublicKey);
    _peerLocks.remove(remoteKexPublicKey);
    _legacySessionKeys.remove(remoteKexPublicKey);
    _legacySeenNonces.remove(remoteKexPublicKey);
    await store.delete(remoteKexPublicKey);
  }

  /// Wipes every stored session. Used by the factory reset.
  Future<void> destroyAllSessions() async {
    _sessions.clear();
    _peerLocks.clear();
    _legacySessionKeys.clear();
    _legacySeenNonces.clear();
    await store.deleteAll();
  }

  /// Encrypts [plaintext] for the holder of [remoteKexPublicKey].
  ///
  /// [aad] must be the canonical envelope header (see C2Message.signingBytes);
  /// decryption only succeeds if the receiver reconstructs the identical header,
  /// which binds the ciphertext to its sender, recipient, type and timestamp.
  Future<String> encryptPayload(
    String plaintext,
    String remoteKexPublicKey, {
    required List<int> aad,
  }) =>
      _withPeer(remoteKexPublicKey, () async {
        final session = await _session(remoteKexPublicKey);
        final keyed = await session.nextSendingKey();

        final box = await _aead.encrypt(
          utf8.encode(plaintext),
          secretKey: keyed.key,
          nonce: _aead.newNonce(),
          aad: [...aad, 0, ...keyed.header.canonical],
        );

        await _persist(remoteKexPublicKey, session);

        return base64Encode(utf8.encode(jsonEncode({
          'v': 3,
          'h': keyed.header.toJson(),
          'n': base64Encode(box.nonce),
          'c': base64Encode(box.cipherText),
          'm': base64Encode(box.mac.bytes),
        })));
      });

  /// Decrypts and authenticates a payload from the holder of [remoteKexPublicKey].
  ///
  /// Throws [DecryptionFailure] on any tampering, malformed input, or replay.
  /// There is deliberately no "looks like plaintext, pass it through" path here:
  /// every branch of the caller must handle authenticated data only.
  Future<String> decryptPayload(
    String encryptedBody,
    String remoteKexPublicKey, {
    required List<int> aad,
  }) =>
      _withPeer(remoteKexPublicKey, () async {
        final Map<String, dynamic> payload;
        try {
          payload = jsonDecode(utf8.decode(base64Decode(encryptedBody))) as Map<String, dynamic>;
        } catch (_) {
          throw const DecryptionFailure('malformed ciphertext envelope');
        }

        switch (payload['v']) {
          case 3:
            return _decryptRatcheted(payload, remoteKexPublicKey, aad);
          case 2:
            onLegacyCiphertext?.call(remoteKexPublicKey);
            return _decryptLegacy(payload, remoteKexPublicKey, aad);
          default:
            throw const DecryptionFailure('unsupported ciphertext version');
        }
      });

  Future<String> _decryptRatcheted(
    Map<String, dynamic> payload,
    String remoteKexPublicKey,
    List<int> aad,
  ) async {
    final RatchetHeader header;
    final Uint8List nonce, cipherText, mac;
    try {
      header = RatchetHeader.fromJson(payload['h'] as Map<String, dynamic>);
      nonce = base64Decode(payload['n'] as String);
      cipherText = base64Decode(payload['c'] as String);
      mac = base64Decode(payload['m'] as String);
    } on RatchetFailure catch (e) {
      throw DecryptionFailure(e.reason);
    } catch (_) {
      throw const DecryptionFailure('malformed ciphertext fields');
    }

    final session = await _session(remoteKexPublicKey);

    // Work on a snapshot: a forged or corrupt message must not be able to
    // advance the real chain. Only a successful decryption is committed.
    final snapshot = jsonEncode(await session.toJson());

    final SecretKey messageKey;
    try {
      messageKey = await session.receivingKey(header);
    } on RatchetFailure catch (e) {
      await _restore(remoteKexPublicKey, snapshot);
      throw DecryptionFailure(e.reason);
    }

    final List<int> clear;
    try {
      clear = await _aead.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: messageKey,
        aad: [...aad, 0, ...header.canonical],
      );
    } on SecretBoxAuthenticationError {
      await _restore(remoteKexPublicKey, snapshot);
      throw const DecryptionFailure('authentication tag mismatch');
    } catch (_) {
      await _restore(remoteKexPublicKey, snapshot);
      throw const DecryptionFailure('decryption error');
    }

    await _persist(remoteKexPublicKey, session);

    try {
      return utf8.decode(clear);
    } catch (_) {
      throw const DecryptionFailure('plaintext is not valid UTF-8');
    }
  }

  /// Rolls a session back to [snapshot] after a failed decryption.
  Future<void> _restore(String peerKey, String snapshot) async {
    try {
      final rolledBack = await DoubleRatchetSession.fromJson(
        jsonDecode(snapshot) as Map<String, dynamic>,
      );
      _sessions[peerKey] = rolledBack;
    } catch (e) {
      debugPrint('[E2EE] Could not roll back ratchet state: $e');
    }
  }

  /// Legacy static-static path, for inbound v2 traffic only.
  ///
  /// Retained so a squad does not have to update every device at the same
  /// moment. It has no forward secrecy, which is the whole reason v3 exists, so
  /// receipt is reported to the caller.
  Future<String> _decryptLegacy(
    Map<String, dynamic> payload,
    String remoteKexPublicKey,
    List<int> aad,
  ) async {
    final Uint8List nonce, cipherText, mac;
    try {
      nonce = base64Decode(payload['n'] as String);
      cipherText = base64Decode(payload['c'] as String);
      mac = base64Decode(payload['m'] as String);
    } catch (_) {
      throw const DecryptionFailure('malformed ciphertext fields');
    }

    final nonceKey = base64Encode(nonce);
    final seen = _legacySeenNonces.putIfAbsent(remoteKexPublicKey, () => <String>{});
    if (seen.contains(nonceKey)) {
      throw const DecryptionFailure('replayed nonce');
    }

    final key = _legacySessionKeys[remoteKexPublicKey] ??=
        await identity.deriveSharedKey(remoteKexPublicKey, info: _legacyKeyInfo);

    final List<int> clear;
    try {
      clear = await _aead.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: aad,
      );
    } on SecretBoxAuthenticationError {
      throw const DecryptionFailure('authentication tag mismatch');
    } catch (_) {
      throw const DecryptionFailure('decryption error');
    }

    // Only remember nonces that authenticated, so junk traffic cannot grow this set.
    seen.add(nonceKey);
    if (seen.length > 2048) {
      // Bounded window. Ordering is insertion-based, so drop the oldest quarter.
      seen.removeAll(seen.take(512).toList());
    }

    try {
      return utf8.decode(clear);
    } catch (_) {
      throw const DecryptionFailure('plaintext is not valid UTF-8');
    }
  }

  /// Safety number for out-of-band verification, over both identity keys.
  ///
  /// 60 decimal digits in 5-digit groups, read off the full SHA-256 of the
  /// sorted signing keys. Every digit carries entropy — the previous version
  /// collapsed hex letters to a constant, which silently destroyed most of it.
  ///
  /// Deliberately over the long-term identity keys, not ratchet state: it has to
  /// stay stable for the life of the pairing so two operators can compare it at
  /// any time.
  static String computeSafetyNumber(String signPubKeyA, String signPubKeyB) {
    final sorted = [signPubKeyA, signPubKeyB]..sort();
    final digest = hashing.sha256.convert(utf8.encode(sorted.join('|')));

    final digits = StringBuffer();
    for (final byte in digest.bytes) {
      digits.write(byte.toString().padLeft(3, '0'));
    }

    final groups = <String>[];
    for (var i = 0; i + 5 <= 60; i += 5) {
      groups.add(digits.toString().substring(i, i + 5));
    }
    return groups.join(' ');
  }
}
