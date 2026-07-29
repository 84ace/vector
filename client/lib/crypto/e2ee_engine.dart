import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as hashing;

import 'operator_identity.dart';

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
/// Construction: X25519 static-static key agreement -> HKDF-SHA256 -> AES-256-GCM
/// with a fresh random 96-bit nonce per message. The envelope header is bound
/// into the ciphertext as additional authenticated data, so a relay cannot move
/// a message between conversations or rewrite its metadata undetected.
///
/// Scope, stated plainly: this is *not* a ratchet. The pairwise key is static
/// for the lifetime of a contact, so there is no forward secrecy and no
/// post-compromise recovery — stealing a device's key material exposes past
/// captured traffic for that pair. Replacing this with a Double Ratchet is
/// tracked separately; nothing here should be described as Signal or X3DH.
class E2EEEngine {
  static const _keyInfo = 'vector-c2/pairwise/v2';
  static final _aead = AesGcm.with256bits();

  final OperatorIdentity identity;

  /// Cache of derived pairwise keys, keyed by remote X25519 public key.
  /// X25519 + HKDF per message is wasteful on the PTT path, which encrypts
  /// an audio chunk every 600ms.
  final Map<String, SecretKey> _sessionKeys = {};

  /// Nonces already accepted per peer, for replay rejection.
  final Map<String, Set<String>> _seenNonces = {};

  E2EEEngine({required this.identity});

  Future<SecretKey> _sessionKey(String remoteKexPublicKey) async {
    final cached = _sessionKeys[remoteKexPublicKey];
    if (cached != null) return cached;

    final derived = await identity.deriveSharedKey(remoteKexPublicKey, info: _keyInfo);
    _sessionKeys[remoteKexPublicKey] = derived;
    return derived;
  }

  /// Drops cached key material for a peer. Call on unpair.
  void forgetPeer(String remoteKexPublicKey) {
    _sessionKeys.remove(remoteKexPublicKey);
    _seenNonces.remove(remoteKexPublicKey);
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
  }) async {
    final key = await _sessionKey(remoteKexPublicKey);
    final nonce = _aead.newNonce();

    final box = await _aead.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );

    return base64Encode(utf8.encode(jsonEncode({
      'v': 2,
      'n': base64Encode(box.nonce),
      'c': base64Encode(box.cipherText),
      'm': base64Encode(box.mac.bytes),
    })));
  }

  /// Decrypts and authenticates a payload from the holder of [remoteKexPublicKey].
  ///
  /// Throws [DecryptionFailure] on any tampering, malformed input, or replay.
  /// There is deliberately no "looks like plaintext, pass it through" path here:
  /// every branch of the caller must handle authenticated data only.
  Future<String> decryptPayload(
    String encryptedBody,
    String remoteKexPublicKey, {
    required List<int> aad,
  }) async {
    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(utf8.decode(base64Decode(encryptedBody))) as Map<String, dynamic>;
    } catch (_) {
      throw const DecryptionFailure('malformed ciphertext envelope');
    }

    if (payload['v'] != 2) {
      throw const DecryptionFailure('unsupported ciphertext version');
    }

    final Uint8List nonce, cipherText, mac;
    try {
      nonce = base64Decode(payload['n'] as String);
      cipherText = base64Decode(payload['c'] as String);
      mac = base64Decode(payload['m'] as String);
    } catch (_) {
      throw const DecryptionFailure('malformed ciphertext fields');
    }

    final nonceKey = base64Encode(nonce);
    final seen = _seenNonces.putIfAbsent(remoteKexPublicKey, () => <String>{});
    if (seen.contains(nonceKey)) {
      throw const DecryptionFailure('replayed nonce');
    }

    final key = await _sessionKey(remoteKexPublicKey);
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
      final drop = seen.take(512).toList();
      seen.removeAll(drop);
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
