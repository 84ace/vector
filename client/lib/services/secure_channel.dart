import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../crypto/e2ee_engine.dart';
import '../crypto/group_engine.dart';
import '../crypto/operator_identity.dart';
import '../models/c2_message.dart';
import '../models/operator_profile.dart';

/// A message that has passed every check and may be acted on.
class OpenedMessage {
  final C2Message envelope;
  final String plaintext;

  /// The contact the envelope was cryptographically proven to come from.
  /// Null only for team traffic from an operator we have not paired with, which
  /// callers must treat as untrusted and generally drop.
  final OperatorProfile? sender;

  const OpenedMessage({
    required this.envelope,
    required this.plaintext,
    required this.sender,
  });
}

/// Why an inbound envelope was rejected. Surfaced to the event log so operators
/// can see hostile traffic rather than having it silently disappear.
enum RejectionReason {
  badSignature,
  unknownSender,
  notForMe,
  decryptionFailed,
  malformed,
}

class RejectedMessage {
  final C2Message envelope;
  final RejectionReason reason;
  final String detail;

  const RejectedMessage(this.envelope, this.reason, this.detail);
}

/// SecureChannel is the single place where envelopes are sealed and opened.
///
/// Every inbound envelope goes through [open], which enforces, in order:
///   1. the signature verifies under the attached identity key;
///   2. the claimed sender ID is the one derived from that key;
///   3. the sender is a contact we have actually paired with;
///   4. the body decrypts under a key derived from *our stored copy* of that
///      contact's key-agreement key — never a key carried by the message.
///
/// Step 4 is the one that closes the old impersonation hole: previously the
/// receiver derived a session key from whatever public key the message brought
/// with it, so any sender could produce readable traffic under any name.
class SecureChannel {
  final OperatorIdentity identity;
  final E2EEEngine pairwise;
  final TeamGroupEngine team;

  /// Resolves a verified operator ID to a paired contact, or null if unknown.
  final OperatorProfile? Function(String operatorId) lookupContact;

  SecureChannel({
    required this.identity,
    required this.pairwise,
    required this.team,
    required this.lookupContact,
  });

  String get myOperatorId => identity.operatorId;

  String _newId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  /// Seals [plaintext] for a single paired contact and signs the envelope.
  Future<C2Message> sealDirect({
    required MessageType type,
    required OperatorProfile recipient,
    required String plaintext,
    String? idPrefix,
  }) async {
    if (!recipient.hasValidKeys) {
      throw StateError('Contact ${recipient.callsign} has no keys; re-pair required.');
    }

    final id = _newId(idPrefix ?? 'msg');
    final timestamp = DateTime.now();

    final aad = C2Message.aadFor(
      id: id,
      type: type,
      senderId: identity.operatorId,
      senderSignKey: identity.signPublicKey,
      recipientId: recipient.id,
      timestamp: timestamp,
    );

    final body = await pairwise.encryptPayload(plaintext, recipient.kexPublicKey, aad: aad);

    final envelope = C2Message(
      id: id,
      type: type,
      senderId: identity.operatorId,
      senderSignKey: identity.signPublicKey,
      recipientId: recipient.id,
      encryptedBody: body,
      decryptedBody: plaintext,
      timestamp: timestamp,
      isMe: true,
      status: MessageStatus.sending,
    );

    return envelope.signed(identity);
  }

  /// Seals [plaintext] for the whole team under the current epoch key.
  Future<C2Message> sealTeam({
    required MessageType type,
    required String plaintext,
    String? idPrefix,
  }) async {
    final id = _newId(idPrefix ?? 'team');
    final timestamp = DateTime.now();

    final aad = C2Message.aadFor(
      id: id,
      type: type,
      senderId: identity.operatorId,
      senderSignKey: identity.signPublicKey,
      groupId: team.groupId,
      timestamp: timestamp,
    );

    final body = await team.encryptGroupMessage(plaintext, aad: aad);

    final envelope = C2Message(
      id: id,
      type: type,
      senderId: identity.operatorId,
      senderSignKey: identity.signPublicKey,
      groupId: team.groupId,
      encryptedBody: body,
      decryptedBody: plaintext,
      timestamp: timestamp,
      isMe: true,
      status: MessageStatus.sending,
    );

    return envelope.signed(identity);
  }

  /// Verifies and decrypts an inbound envelope.
  ///
  /// Returns an [OpenedMessage] on success, or a [RejectedMessage] describing
  /// why it was refused. Callers must not act on anything but an OpenedMessage.
  Future<Object> open(C2Message msg) async {
    if (msg.senderId == identity.operatorId) {
      return RejectedMessage(msg, RejectionReason.malformed, 'envelope loops back to self');
    }

    if (!await msg.verifySignature()) {
      return RejectedMessage(
        msg,
        RejectionReason.badSignature,
        'signature invalid or sender ID does not match its identity key',
      );
    }

    final isDirect = msg.type == MessageType.chat1to1 || msg.type == MessageType.callSignaling;
    if (isDirect && msg.recipientId != identity.operatorId) {
      return RejectedMessage(msg, RejectionReason.notForMe, 'addressed to ${msg.recipientId}');
    }

    final contact = lookupContact(msg.senderId);
    if (contact == null || !contact.hasValidKeys) {
      return RejectedMessage(msg, RejectionReason.unknownSender, 'sender is not a paired contact');
    }

    try {
      final plaintext = isDirect
          ? await pairwise.decryptPayload(msg.encryptedBody, contact.kexPublicKey, aad: msg.aad)
          : await team.decryptGroupMessage(msg.encryptedBody, aad: msg.aad, senderId: msg.senderId);

      return OpenedMessage(
        envelope: msg.copyWith(decryptedText: plaintext, newStatus: MessageStatus.delivered),
        plaintext: plaintext,
        sender: contact,
      );
    } on DecryptionFailure catch (e) {
      return RejectedMessage(msg, RejectionReason.decryptionFailed, e.reason);
    } catch (e) {
      return RejectedMessage(msg, RejectionReason.decryptionFailed, 'unexpected: $e');
    }
  }

  /// Builds the signed, unencrypted bootstrap envelope that introduces us to a
  /// peer we have scanned but who does not yet have a contact record for us.
  Future<C2Message> sealPairRequest({
    required String recipientId,
    required OperatorProfile me,
    required String tokenId,
  }) async {
    final envelope = C2Message(
      id: _newId('pair'),
      type: MessageType.pairRequest,
      senderId: identity.operatorId,
      senderSignKey: identity.signPublicKey,
      recipientId: recipientId,
      encryptedBody: jsonEncode(pairingPayload(me, tokenId)),
      timestamp: DateTime.now(),
      isMe: true,
      status: MessageStatus.sending,
    );
    return envelope.signed(identity);
  }

  /// Opens a pairing request from an operator we have no contact record for.
  ///
  /// Deliberately the one path that accepts keys carried by a message, because
  /// it is the path that bootstraps trust — there is nothing else to check
  /// against yet. It is safe to the extent that it is bounded:
  ///   * the signature must verify, and the sender ID must be derived from the
  ///     key that signed it, so the request cannot be sent under a borrowed name;
  ///   * the keys inside the payload must be the same ones the envelope was
  ///     signed with, so the body cannot smuggle in a different identity;
  ///   * nothing is trusted until the operator approves it, having compared the
  ///     safety number out of band.
  /// Every *other* message type resolves keys from stored contacts only.
  Future<OperatorProfile?> openPairRequest(C2Message msg) async {
    if (msg.type != MessageType.pairRequest) return null;
    if (msg.recipientId != identity.operatorId) return null;
    if (!await msg.verifySignature()) {
      debugPrint('[PAIRING] Rejected pair request with invalid signature');
      return null;
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(msg.encryptedBody) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    final applicant = contactFromPairingPayload(data);
    if (applicant == null) return null;

    // The payload's identity must be the one that signed the envelope.
    if (applicant.signPublicKey != msg.senderSignKey || applicant.id != msg.senderId) {
      debugPrint('[PAIRING] Rejected pair request: payload identity differs from signer');
      return null;
    }
    if (applicant.id == identity.operatorId) return null;

    return applicant;
  }

  /// Opens an envelope and returns its payload as a JSON map, or null if the
  /// message was rejected or is not a JSON control payload.
  Future<Map<String, dynamic>?> openControlPayload(C2Message msg) async {
    final result = await open(msg);
    if (result is! OpenedMessage) return null;
    try {
      final decoded = jsonDecode(result.plaintext);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Builds the pairing payload exchanged over the QR/manual channel.
  ///
  /// This is the only place identity keys travel outside an encrypted envelope,
  /// and it goes over an out-of-band channel the operator controls (a screen
  /// they show, or a code they read out) rather than the network.
  Map<String, dynamic> pairingPayload(OperatorProfile me, String tokenId) => {
        'c2_version': '2.0',
        'token_id': tokenId,
        'operator_id': identity.operatorId,
        'callsign': me.callsign,
        'name': me.name,
        'sign_public_key': identity.signPublicKey,
        'kex_public_key': identity.kexPublicKey,
      };

  /// Parses a scanned pairing payload into a contact, rejecting any payload
  /// whose operator ID does not match its own signing key.
  static OperatorProfile? contactFromPairingPayload(Map<String, dynamic> data) {
    final signKey = data['sign_public_key'] as String?;
    final kexKey = data['kex_public_key'] as String?;
    final claimedId = data['operator_id'] as String?;

    if (signKey == null || signKey.isEmpty || kexKey == null || kexKey.isEmpty) {
      return null; // Pre-v2 pairing code; the peer must upgrade.
    }

    String derivedId;
    try {
      derivedId = OperatorIdentity.deriveOperatorId(signKey);
    } catch (_) {
      return null;
    }
    if (claimedId != null && claimedId != derivedId) {
      debugPrint('[PAIRING] Rejected payload: ID $claimedId does not match its key');
      return null;
    }

    return OperatorProfile(
      id: derivedId,
      callsign: (data['callsign'] as String?)?.trim().isNotEmpty == true
          ? data['callsign'] as String
          : 'OPERATOR',
      name: (data['name'] as String?) ?? 'Unknown Operator',
      role: OperatorRole.operator,
      avatarBase64: '',
      signPublicKey: signKey,
      kexPublicKey: kexKey,
      lastSeen: DateTime.now(),
    );
  }
}
