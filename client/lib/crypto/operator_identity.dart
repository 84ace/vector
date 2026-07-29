import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Raised when the platform keystore cannot be reached.
///
/// This is deliberately fatal rather than something the app works around. The
/// alternative — quietly keeping private keys in ordinary preferences — would
/// leave the app looking like it worked while silently voiding the guarantee
/// the rest of the system is built on.
class SecureStorageUnavailable implements Exception {
  final String detail;
  final String remedy;

  const SecureStorageUnavailable(this.detail, this.remedy);

  @override
  String toString() => 'SecureStorageUnavailable: $detail';
}

/// OperatorIdentity holds the long-term cryptographic identity of this device.
///
/// Two keypairs are held:
///   * Ed25519 signing pair  - authenticates every envelope this device emits
///                             and answers the relay's connection challenge.
///   * X25519 key-agreement  - establishes pairwise secrets with contacts.
///
/// The operator ID is *derived from* the signing public key, which makes it
/// self-certifying: a peer can confirm that whoever signed an envelope really
/// owns the claimed ID without consulting any server or directory.
class OperatorIdentity {
  static const _storageKey = 'c2_identity_v2';
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  static final _ed25519 = Ed25519();
  static final _x25519 = X25519();

  final SimpleKeyPair signingKeyPair;
  final SimpleKeyPair agreementKeyPair;

  /// Base64 Ed25519 public key. Published in envelopes and pairing payloads.
  final String signPublicKey;

  /// Base64 X25519 public key. Published in pairing payloads only.
  final String kexPublicKey;

  /// Self-certifying operator ID: `op-<first 16 hex of sha256(signPublicKey)>`.
  final String operatorId;

  OperatorIdentity._({
    required this.signingKeyPair,
    required this.agreementKeyPair,
    required this.signPublicKey,
    required this.kexPublicKey,
    required this.operatorId,
  });

  /// Derives the canonical operator ID for a given base64 Ed25519 public key.
  ///
  /// Any peer can run this over the `sender_sign_key` on an envelope and compare
  /// it against `sender_id`; a mismatch means the sender is lying about who it is.
  static String deriveOperatorId(String signPublicKeyBase64) {
    final digest = hashing.sha256.convert(base64Decode(signPublicKeyBase64));
    return 'op-${digest.toString().substring(0, 16)}';
  }

  /// Loads the stored identity, generating a fresh one on first launch.
  ///
  /// Private key material lives in the iOS Keychain / Android Keystore-backed
  /// EncryptedSharedPreferences, never in SharedPreferences.
  /// Throws [SecureStorageUnavailable] if the platform keystore is unreachable.
  static Future<OperatorIdentity> loadOrCreate() async {
    final String? stored;
    try {
      stored = await _secureStorage.read(key: _storageKey);
    } on PlatformException catch (e) {
      throw _describeStorageFailure(e);
    }

    if (stored != null) {
      try {
        return await _fromJson(jsonDecode(stored) as Map<String, dynamic>);
      } on PlatformException catch (e) {
        throw _describeStorageFailure(e);
      } catch (_) {
        // Corrupt or truncated key blob: fall through and re-key the device.
        // Contacts will need to re-pair, which is the correct failure mode.
        try {
          await _secureStorage.delete(key: _storageKey);
        } on PlatformException catch (e) {
          throw _describeStorageFailure(e);
        }
      }
    }

    try {
      return await _generate();
    } on PlatformException catch (e) {
      throw _describeStorageFailure(e);
    }
  }

  /// Turns an opaque keystore error into something an operator can act on.
  static SecureStorageUnavailable _describeStorageFailure(PlatformException e) {
    // errSecMissingEntitlement. On Apple platforms this always means the app
    // was built without keychain access declared, not that anything is wrong
    // with the device.
    if (e.code == '-34018' || (e.message?.contains('entitlement') ?? false)) {
      return const SecureStorageUnavailable(
        'The app is not permitted to use the system keychain.',
        'This build is not signed with a development certificate, so the '
            'sandbox gives it no keychain identity. Open the Xcode project '
            '(macos/Runner.xcworkspace or ios/Runner.xcworkspace), select the '
            'Runner target, and under Signing & Capabilities pick a Team — a '
            'free personal Apple ID is enough. Then rebuild.',
      );
    }

    return SecureStorageUnavailable(
      'The system keystore could not be reached (${e.code}).',
      'Vector C2 stores your identity keys in the device keystore and will not '
          'fall back to unprotected storage. Check the device is unlocked and '
          'the app is correctly signed, then try again.',
    );
  }

  /// Builds an ephemeral identity that is never written to secure storage.
  /// Used by tests, which have no platform keychain available.
  @visibleForTesting
  static Future<OperatorIdentity> forTesting() async => _build(
        await _ed25519.newKeyPair(),
        await _x25519.newKeyPair(),
      );

  static Future<OperatorIdentity> _generate() async {
    final signing = await _ed25519.newKeyPair();
    final agreement = await _x25519.newKeyPair();

    final identity = await _build(signing, agreement);
    await _secureStorage.write(
      key: _storageKey,
      value: jsonEncode({
        'sign_private': base64Encode(await signing.extractPrivateKeyBytes()),
        'kex_private': base64Encode(await agreement.extractPrivateKeyBytes()),
      }),
    );
    return identity;
  }

  static Future<OperatorIdentity> _fromJson(Map<String, dynamic> json) async {
    final signing = await _ed25519.newKeyPairFromSeed(
      base64Decode(json['sign_private'] as String),
    );
    final agreement = await _x25519.newKeyPairFromSeed(
      base64Decode(json['kex_private'] as String),
    );
    return _build(signing, agreement);
  }

  static Future<OperatorIdentity> _build(
    SimpleKeyPair signing,
    SimpleKeyPair agreement,
  ) async {
    final signPub = base64Encode((await signing.extractPublicKey()).bytes);
    final kexPub = base64Encode((await agreement.extractPublicKey()).bytes);
    return OperatorIdentity._(
      signingKeyPair: signing,
      agreementKeyPair: agreement,
      signPublicKey: signPub,
      kexPublicKey: kexPub,
      operatorId: deriveOperatorId(signPub),
    );
  }

  /// Signs [message] with the long-term Ed25519 identity key.
  Future<String> sign(List<int> message) async {
    final signature = await _ed25519.sign(message, keyPair: signingKeyPair);
    return base64Encode(signature.bytes);
  }

  /// Verifies an Ed25519 [signatureBase64] over [message] under [signPublicKeyBase64].
  static Future<bool> verify(
    List<int> message,
    String signatureBase64,
    String signPublicKeyBase64,
  ) async {
    try {
      return await _ed25519.verify(
        message,
        signature: Signature(
          base64Decode(signatureBase64),
          publicKey: SimplePublicKey(
            base64Decode(signPublicKeyBase64),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Performs X25519 with [remoteKexPublicKey] and stretches the raw shared
  /// point into a 256-bit AEAD key with HKDF-SHA256.
  ///
  /// The salt is the pair of public keys in sorted order so both sides derive
  /// the same key regardless of who initiates.
  Future<SecretKey> deriveSharedKey(String remoteKexPublicKey, {required String info}) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: agreementKeyPair,
      remotePublicKey: SimplePublicKey(
        base64Decode(remoteKexPublicKey),
        type: KeyPairType.x25519,
      ),
    );

    final salt = ([kexPublicKey, remoteKexPublicKey]..sort()).join('|');
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: shared,
      nonce: Uint8List.fromList(utf8.encode(salt)),
      info: utf8.encode(info),
    );
  }

  /// Wipes identity material. Used by the settings "purge device" action.
  static Future<void> destroy() => _secureStorage.delete(key: _storageKey);
}
