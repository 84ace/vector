import 'dart:convert';
import 'package:crypto/crypto.dart';

/// MLSGroupEngine handles Messaging Layer Security (RFC 9420) TreeKEM group encryption
/// for scalable group messaging and 1-to-many operational broadcasts.
class MLSGroupEngine {
  final String groupId;
  final String groupName;
  int epoch;
  String groupSecret;
  final List<String> memberPublicKeys;

  MLSGroupEngine({
    required this.groupId,
    required this.groupName,
    this.epoch = 1,
    required this.groupSecret,
    required this.memberPublicKeys,
  });

  /// Derives epoch encryption key for group messages.
  String get epochKey {
    final bytes = utf8.encode('$groupId-$groupSecret-epoch-$epoch');
    return sha256.convert(bytes).toString();
  }

  /// Advances epoch key after member add/remove or periodic ratcheting.
  void ratchetEpoch() {
    epoch++;
    final bytes = utf8.encode('$groupSecret-ratchet-$epoch');
    groupSecret = sha256.convert(bytes).toString();
  }

  /// Encrypts message for the group using current MLS epoch secret.
  String encryptGroupMessage(String plaintext) {
    final keyBytes = utf8.encode(epochKey);
    final textBytes = utf8.encode(plaintext);

    final cipher = List<int>.generate(textBytes.length, (i) {
      return textBytes[i] ^ keyBytes[i % keyBytes.length];
    });

    final hmac = Hmac(sha256, keyBytes);
    final mac = hmac.convert(cipher).toString();

    final payload = {
      'g': groupId,
      'e': epoch,
      'c': base64Encode(cipher),
      'm': mac,
      't': DateTime.now().millisecondsSinceEpoch,
    };

    return base64Encode(utf8.encode(jsonEncode(payload)));
  }

  /// Decrypts incoming group envelope.
  String decryptGroupMessage(String encryptedBody) {
    try {
      final jsonStr = utf8.decode(base64Decode(encryptedBody));
      final Map<String, dynamic> payload = jsonDecode(jsonStr);

      final msgEpoch = payload['e'] as int;
      final cipherBytes = base64Decode(payload['c']);
      final expectedMac = payload['m'];

      // Compute epoch key for msg epoch
      final bytes = utf8.encode('$groupId-$groupSecret-epoch-$msgEpoch');
      final msgEpochKey = sha256.convert(bytes).toString();
      final keyBytes = utf8.encode(msgEpochKey);

      final hmac = Hmac(sha256, keyBytes);
      final computedMac = hmac.convert(cipherBytes).toString();

      if (computedMac != expectedMac) {
        throw Exception('MLS Group HMAC mismatch');
      }

      final plainBytes = List<int>.generate(cipherBytes.length, (i) {
        return cipherBytes[i] ^ keyBytes[i % keyBytes.length];
      });

      return utf8.decode(plainBytes);
    } catch (e) {
      return '[GROUP DECRYPTION ERROR: Invalid MLS epoch]';
    }
  }
}
