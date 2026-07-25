enum MessageType { chat1to1, chatGroup, broadcast, callSignaling, telemetry, sosAlert, waypoint }

enum MessageStatus { sending, sent, delivered, read }

class C2Message {
  final String id;
  final MessageType type;
  final String senderId;
  final String? senderPublicKey;
  final String? recipientId;
  final String? groupId;
  final String encryptedBody;
  final String? decryptedBody;
  final DateTime timestamp;
  final bool isMe;
  final MessageStatus status;

  C2Message({
    required this.id,
    required this.type,
    required this.senderId,
    this.senderPublicKey,
    this.recipientId,
    this.groupId,
    required this.encryptedBody,
    this.decryptedBody,
    required this.timestamp,
    this.isMe = false,
    this.status = MessageStatus.sent,
  });

  Map<String, dynamic> toEnvelopeJson() => {
        'id': id,
        'type': _typeToString(type),
        'sender_id': senderId,
        if (senderPublicKey != null) 'sender_public_key': senderPublicKey,
        if (recipientId != null) 'recipient_id': recipientId,
        if (groupId != null) 'group_id': groupId,
        'encrypted_body': encryptedBody,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'status': status.name,
      };

  factory C2Message.fromEnvelopeJson(Map<String, dynamic> json, String myOperatorId) {
    final sender = json['sender_id'] ?? '';
    return C2Message(
      id: json['id'] ?? '',
      type: _stringToType(json['type']),
      senderId: sender,
      senderPublicKey: json['sender_public_key'],
      recipientId: json['recipient_id'],
      groupId: json['group_id'],
      encryptedBody: json['encrypted_body'] ?? '',
      timestamp: json['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['timestamp'])
          : DateTime.now(),
      isMe: sender == myOperatorId,
      status: _stringToStatus(json['status']),
    );
  }

  static String _typeToString(MessageType type) {
    switch (type) {
      case MessageType.chat1to1:
        return 'CHAT_1TO1';
      case MessageType.chatGroup:
        return 'CHAT_GROUP';
      case MessageType.broadcast:
        return 'BROADCAST';
      case MessageType.callSignaling:
        return 'CALL_SIGNALING';
      case MessageType.telemetry:
        return 'TELEMETRY';
      case MessageType.sosAlert:
        return 'SOS_ALERT';
      case MessageType.waypoint:
        return 'WAYPOINT';
    }
  }

  static MessageType _stringToType(String? typeStr) {
    switch (typeStr) {
      case 'CHAT_1TO1':
        return MessageType.chat1to1;
      case 'CHAT_GROUP':
        return MessageType.chatGroup;
      case 'BROADCAST':
        return MessageType.broadcast;
      case 'CALL_SIGNALING':
        return MessageType.callSignaling;
      case 'TELEMETRY':
        return MessageType.telemetry;
      case 'SOS_ALERT':
        return MessageType.sosAlert;
      case 'WAYPOINT':
        return MessageType.waypoint;
      default:
        return MessageType.chat1to1;
    }
  }

  static MessageStatus _stringToStatus(String? statusStr) {
    switch (statusStr) {
      case 'sending':
        return MessageStatus.sending;
      case 'sent':
        return MessageStatus.sent;
      case 'delivered':
        return MessageStatus.delivered;
      case 'read':
        return MessageStatus.read;
      default:
        return MessageStatus.sent;
    }
  }

  C2Message copyWith({
    String? decryptedText,
    MessageStatus? newStatus,
  }) {
    return C2Message(
      id: id,
      type: type,
      senderId: senderId,
      senderPublicKey: senderPublicKey,
      recipientId: recipientId,
      groupId: groupId,
      encryptedBody: encryptedBody,
      decryptedBody: decryptedText ?? decryptedBody,
      timestamp: timestamp,
      isMe: isMe,
      status: newStatus ?? status,
    );
  }

  C2Message copyWithDecrypted(String decryptedText) {
    return copyWith(decryptedText: decryptedText);
  }
}
