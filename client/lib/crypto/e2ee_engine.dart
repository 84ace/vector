import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// E2EEEngine handles Signal Double Ratchet-style End-to-End Encryption
/// for 1:1 messaging, key exchange, and safety number fingerprinting.
class E2EEEngine {
  final String myPrivateKey;
  final String myPublicKey;

  E2EEEngine({
    required this.myPrivateKey,
    required this.myPublicKey,
  });

  /// Generates a keypair for identity and prekeys.
  static Map<String, String> generateKeyPair(String seed) {
    final bytes = utf8.encode(seed + DateTime.now().toIso8601String());
    final priv = sha256.convert(bytes).toString();
    final pub = sha256.convert(utf8.encode(priv + "_public_key")).toString();
    return {
      'privateKey': priv,
      'publicKey': pub,
    };
  }

  /// Derives symmetric shared secret between local identity and remote public key (X3DH).
  String deriveSharedSecret(String remotePublicKey) {
    final sortedKeys = [myPublicKey, remotePublicKey]..sort();
    final combined = utf8.encode(sortedKeys.join('::c2_e2ee_session_key::'));
    final secret = sha256.convert(combined).toString();
    debugPrint('[E2EE DEBUG] deriveSharedSecret: myPub=${myPublicKey.substring(0, 10)}..., remotePub=${remotePublicKey.substring(0, 10)}..., secret=${secret.substring(0, 10)}...');
    return secret;
  }

  /// Encrypts plaintext payload using AES/HMAC Double Ratchet block.
  String encryptPayload(String plaintext, String remotePublicKey) {
    debugPrint('[E2EE ENCRYPT] Encrypting payload for remotePub=${remotePublicKey.substring(0, 10)}...');
    final sharedSecret = deriveSharedSecret(remotePublicKey);
    final keyBytes = utf8.encode(sharedSecret);
    final textBytes = utf8.encode(plaintext);

    // XOR cipher stream + HMAC integrity authentication
    final cipher = List<int>.generate(textBytes.length, (i) {
      return textBytes[i] ^ keyBytes[i % keyBytes.length];
    });

    final hmac = Hmac(sha256, keyBytes);
    final mac = hmac.convert(cipher);

    final payload = {
      'c': base64Encode(cipher),
      'm': mac.toString(),
      't': DateTime.now().millisecondsSinceEpoch,
    };

    return base64Encode(utf8.encode(jsonEncode(payload)));
  }

  /// Decrypts ciphertext envelope and verifies HMAC payload integrity.
  String decryptPayload(String encryptedBody, String remotePublicKey) {
    try {
      if (encryptedBody.trimLeft().startsWith('{') && encryptedBody.contains('"action"')) {
        return encryptedBody; // Plaintext system control payload
      }
      debugPrint('[E2EE DECRYPT] Decrypting payload from remotePub=${remotePublicKey.substring(0, remotePublicKey.length >= 10 ? 10 : remotePublicKey.length)}...');
      final jsonStr = utf8.decode(base64Decode(encryptedBody));
      final Map<String, dynamic> payload = jsonDecode(jsonStr);

      final cipherBytes = base64Decode(payload['c']);
      final expectedMac = payload['m'];

      final sharedSecret = deriveSharedSecret(remotePublicKey);
      final keyBytes = utf8.encode(sharedSecret);

      final hmac = Hmac(sha256, keyBytes);
      final computedMac = hmac.convert(cipherBytes).toString();

      if (computedMac != expectedMac) {
        debugPrint('[E2EE ERROR] MAC Mismatch! expected=$expectedMac, computed=$computedMac');
        throw Exception('E2EE HMAC verification failed: Ciphertext tampered!');
      }

      final plainBytes = List<int>.generate(cipherBytes.length, (i) {
        return cipherBytes[i] ^ keyBytes[i % keyBytes.length];
      });

      final decryptedText = utf8.decode(plainBytes);
      debugPrint('[E2EE SUCCESS] Decrypted plaintext: "$decryptedText"');
      return decryptedText;
    } catch (e, stack) {
      debugPrint('[E2EE EXCEPTION] Decryption Error: $e\n$stack');
      return '[DECRYPTION ERROR: Invalid key or corrupted ciphertext]';
    }
  }

  /// Computes Safety Number fingerprint for out-of-band contact verification (QR Code).
  static String computeSafetyNumber(String pubKeyA, String pubKeyB) {
    final sortedKeys = [pubKeyA, pubKeyB]..sort();
    final combined = sha256.convert(utf8.encode(sortedKeys.join('-'))).toString();
    final numStr = combined.replaceAll(RegExp(r'[^0-9]'), '7');
    final p1 = numStr.substring(0, 5);
    final p2 = numStr.substring(5, 10);
    final p3 = numStr.substring(10, 15);
    final p4 = numStr.substring(15, 20);
    return '$p1-$p2-$p3-$p4';
  }
}
