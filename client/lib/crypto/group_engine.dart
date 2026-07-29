import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'e2ee_engine.dart';
import 'operator_identity.dart';

/// TeamGroupEngine encrypts one-to-many team traffic: telemetry, operational
/// broadcasts, group chat and SOS beacons.
///
/// Design, stated plainly so nobody mistakes it for something stronger:
/// this is a **shared symmetric team key**, not MLS and not TreeKEM. The key is
/// 256 random bits generated on the device and exchanged with each contact over
/// the authenticated pairwise channel during pairing. Every paired member can
/// therefore read all team traffic, and removing a member requires an explicit
/// rekey that is delivered pairwise to the members who remain.
///
/// What it does provide: confidentiality and integrity against anyone who is
/// not a paired member, including the relay operator. What it does not provide:
/// forward secrecy, or protection from a member who has been removed but kept a
/// copy of an old epoch key.
class TeamGroupEngine {
  static const _storageKey = 'c2_group_secret_v2';
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  static final _aead = AesGcm.with256bits();
  static final _random = Random.secure();

  final String groupId;
  final String groupName;

  /// Base64 256-bit team secret. Never leaves the device except inside a
  /// pairwise-encrypted pairing payload.
  String groupSecret;
  int epoch;

  /// Derived epoch keys, cached by epoch number. Retaining recent epochs lets
  /// messages that were already in flight during a rekey still open.
  final Map<int, SecretKey> _epochKeys = {};
  final Map<String, Set<String>> _seenNonces = {};

  TeamGroupEngine({
    required this.groupId,
    required this.groupName,
    required this.groupSecret,
    this.epoch = 1,
  });

  /// Loads the persisted team secret, generating one on first launch.
  static Future<TeamGroupEngine> loadOrCreate({
    required String groupId,
    required String groupName,
  }) async {
    final String? stored;
    try {
      stored = await _secureStorage.read(key: _storageKey);
    } on PlatformException catch (e) {
      throw SecureStorageUnavailable(
        'The system keystore could not be reached (${e.code}).',
        'Vector C2 stores the team key in the device keystore and will not fall '
            'back to unprotected storage.',
      );
    }

    if (stored != null) {
      try {
        final json = jsonDecode(stored) as Map<String, dynamic>;
        return TeamGroupEngine(
          groupId: groupId,
          groupName: groupName,
          groupSecret: json['secret'] as String,
          epoch: json['epoch'] as int? ?? 1,
        );
      } catch (_) {
        await _secureStorage.delete(key: _storageKey);
      }
    }

    final engine = TeamGroupEngine(
      groupId: groupId,
      groupName: groupName,
      groupSecret: generateSecret(),
    );
    await engine.persist();
    return engine;
  }

  static String generateSecret() {
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return base64Encode(bytes);
  }

  Future<void> persist() => _secureStorage.write(
        key: _storageKey,
        value: jsonEncode({'secret': groupSecret, 'epoch': epoch}),
      );

  /// Converges two independently generated team secrets onto one value.
  ///
  /// Both devices generate a secret at first launch, so pairing has to pick a
  /// winner. Choosing the lexicographically smaller secret is deterministic and
  /// order-independent: whatever sequence a squad pairs in, everyone lands on
  /// the same key without a coordinator.
  ///
  /// Returns true if this device adopted the peer's secret.
  Future<bool> mergeWithPeerSecret(String peerSecret, int peerEpoch) async {
    if (peerSecret.isEmpty || peerSecret == groupSecret) return false;

    final adopt = peerSecret.compareTo(groupSecret) < 0;
    if (adopt) {
      groupSecret = peerSecret;
      epoch = max(epoch, peerEpoch);
      _epochKeys.clear();
      await persist();
    }
    return adopt;
  }

  /// Rotates to a fresh team secret after a membership change.
  ///
  /// The caller is responsible for delivering [groupSecret] and [epoch] to the
  /// remaining members over the pairwise channel — this must never be a
  /// unilateral local change, or this device silently stops being able to read
  /// its own team's traffic.
  Future<void> rotate() async {
    groupSecret = generateSecret();
    epoch += 1;
    _epochKeys.clear();
    await persist();
  }

  /// Adopts a rekey announced by another member.
  ///
  /// Requires a strictly newer epoch. Accepting an equal epoch would let two
  /// members who rotate at the same time flip each other's key back and forth,
  /// and would let a replayed announcement undo a later rotation.
  Future<bool> adoptRekey(String newSecret, int newEpoch) async {
    if (newSecret.isEmpty || newEpoch <= epoch) return false;

    groupSecret = newSecret;
    epoch = newEpoch;
    _epochKeys.clear();
    await persist();
    return true;
  }

  Future<SecretKey> _epochKey(int forEpoch) async {
    final cached = _epochKeys[forEpoch];
    if (cached != null) return cached;

    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(base64Decode(groupSecret)),
      nonce: utf8.encode(groupId),
      info: utf8.encode('vector-c2/group/v2/epoch/$forEpoch'),
    );

    _epochKeys[forEpoch] = derived;
    if (_epochKeys.length > 8) {
      final oldest = _epochKeys.keys.reduce(min);
      _epochKeys.remove(oldest);
    }
    return derived;
  }

  /// Encrypts [plaintext] for the team under the current epoch key.
  Future<String> encryptGroupMessage(String plaintext, {required List<int> aad}) async {
    final key = await _epochKey(epoch);
    final box = await _aead.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: _aead.newNonce(),
      aad: aad,
    );

    return base64Encode(utf8.encode(jsonEncode({
      'v': 2,
      'g': groupId,
      'e': epoch,
      'n': base64Encode(box.nonce),
      'c': base64Encode(box.cipherText),
      'm': base64Encode(box.mac.bytes),
    })));
  }

  /// Decrypts a team message. Throws [DecryptionFailure] on any tampering,
  /// unknown epoch, or replay — callers must not render the failure as content.
  Future<String> decryptGroupMessage(
    String encryptedBody, {
    required List<int> aad,
    required String senderId,
  }) async {
    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(utf8.decode(base64Decode(encryptedBody))) as Map<String, dynamic>;
    } catch (_) {
      throw const DecryptionFailure('malformed group envelope');
    }

    if (payload['v'] != 2) {
      throw const DecryptionFailure('unsupported group ciphertext version');
    }
    if (payload['g'] != groupId) {
      throw const DecryptionFailure('message is for a different team');
    }

    final msgEpoch = payload['e'];
    if (msgEpoch is! int) {
      throw const DecryptionFailure('missing epoch');
    }
    if (msgEpoch > epoch || epoch - msgEpoch > 4) {
      throw const DecryptionFailure('epoch outside accepted window');
    }

    final Uint8List nonce, cipherText, mac;
    try {
      nonce = base64Decode(payload['n'] as String);
      cipherText = base64Decode(payload['c'] as String);
      mac = base64Decode(payload['m'] as String);
    } catch (_) {
      throw const DecryptionFailure('malformed group ciphertext fields');
    }

    final nonceKey = base64Encode(nonce);
    final seen = _seenNonces.putIfAbsent(senderId, () => <String>{});
    if (seen.contains(nonceKey)) {
      throw const DecryptionFailure('replayed group nonce');
    }

    final key = await _epochKey(msgEpoch);
    final List<int> clear;
    try {
      clear = await _aead.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: aad,
      );
    } on SecretBoxAuthenticationError {
      throw const DecryptionFailure('group authentication tag mismatch');
    } catch (_) {
      throw const DecryptionFailure('group decryption error');
    }

    seen.add(nonceKey);
    if (seen.length > 2048) {
      seen.removeAll(seen.take(512).toList());
    }

    try {
      return utf8.decode(clear);
    } catch (_) {
      throw const DecryptionFailure('group plaintext is not valid UTF-8');
    }
  }

  static Future<void> destroy() => _secureStorage.delete(key: _storageKey);
}
