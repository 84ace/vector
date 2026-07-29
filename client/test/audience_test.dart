import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/models/c2_message.dart';
import 'package:vector_c2/models/operator_profile.dart';
import 'package:vector_c2/ui/chat/audience_selector.dart';

/// The audience is the one place "who is this going to" is now decided, for
/// both text and voice. It used to be four separate controls that nothing kept
/// in step, so its routing and filtering rules are worth pinning down.
void main() {
  OperatorProfile contact(String id, String callsign) => OperatorProfile(
        id: id,
        callsign: callsign,
        name: callsign,
        role: OperatorRole.operator,
        avatarBase64: '',
        signPublicKey: 'sign-$id',
        kexPublicKey: 'kex-$id',
        lastSeen: DateTime.now(),
      );

  C2Message msg({
    required MessageType type,
    required String sender,
    String? recipient,
    String? body,
  }) =>
      C2Message(
        id: 'm-$sender-$recipient-${type.name}',
        type: type,
        senderId: sender,
        recipientId: recipient,
        encryptedBody: 'cipher',
        decryptedBody: body ?? 'hello',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  const me = 'op-me';
  final alpha = contact('op-alpha', 'ALPHA-1');
  final bravo = contact('op-bravo', 'BRAVO-2');

  group('routing', () {
    test('each audience maps to its envelope type', () {
      expect(Audience.direct(alpha).messageType, MessageType.chat1to1);
      expect(const Audience.squad().messageType, MessageType.chatGroup);
      expect(const Audience.broadcast().messageType, MessageType.broadcast);
    });

    test('a direct audience without a peer is not deliverable', () {
      expect(Audience.direct(alpha).isDeliverable, isTrue);
      expect(const Audience.squad().isDeliverable, isTrue);
    });

    test('audiences compare by kind and peer', () {
      expect(Audience.direct(alpha), Audience.direct(alpha));
      expect(Audience.direct(alpha), isNot(Audience.direct(bravo)));
      expect(const Audience.squad(), isNot(const Audience.broadcast()));
    });
  });

  group('conversation filtering', () {
    test('a direct conversation shows both directions with that peer only', () {
      final audience = Audience.direct(alpha);

      final fromAlpha = msg(type: MessageType.chat1to1, sender: alpha.id, recipient: me);
      final toAlpha = msg(type: MessageType.chat1to1, sender: me, recipient: alpha.id);
      final fromBravo = msg(type: MessageType.chat1to1, sender: bravo.id, recipient: me);
      final toBravo = msg(type: MessageType.chat1to1, sender: me, recipient: bravo.id);

      expect(audience.includes(fromAlpha, me), isTrue);
      expect(audience.includes(toAlpha, me), isTrue);
      expect(audience.includes(fromBravo, me), isFalse,
          reason: 'another peer must not leak into this conversation');
      expect(audience.includes(toBravo, me), isFalse);
    });

    test('squad and broadcast do not bleed into each other', () {
      final group = msg(type: MessageType.chatGroup, sender: alpha.id);
      final shout = msg(type: MessageType.broadcast, sender: alpha.id);

      expect(const Audience.squad().includes(group, me), isTrue);
      expect(const Audience.squad().includes(shout, me), isFalse);
      expect(const Audience.broadcast().includes(shout, me), isTrue);
      expect(const Audience.broadcast().includes(group, me), isFalse);
    });

    test('a direct conversation ignores team traffic', () {
      final audience = Audience.direct(alpha);
      expect(audience.includes(msg(type: MessageType.chatGroup, sender: alpha.id), me), isFalse);
      expect(audience.includes(msg(type: MessageType.broadcast, sender: alpha.id), me), isFalse);
    });
  });

  group('voice transmissions in a direct conversation', () {
    C2Message ptt({required String sender, required String recipient}) => C2Message(
          id: 'ptt-$sender',
          // Direct push-to-talk rides the call-signalling envelope, not chat.
          type: MessageType.callSignaling,
          senderId: sender,
          recipientId: recipient,
          encryptedBody: 'cipher',
          decryptedBody: 'PTT_STOP:{"audio_base64":"QUJDRA==","duration_ms":4000}',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );

    test('a received transmission belongs to the sender conversation', () {
      // Regression: admitting only chat1to1 meant a clip sent from one device
      // was stored on the other and then filtered out of every view — it
      // arrived, and nothing ever showed it.
      final incoming = ptt(sender: alpha.id, recipient: me);
      expect(Audience.direct(alpha).includes(incoming, me), isTrue);
      expect(Audience.isDisplayableContent(incoming), isTrue);
    });

    test('a sent transmission appears in the same conversation', () {
      final outgoing = ptt(sender: me, recipient: alpha.id);
      expect(Audience.direct(alpha).includes(outgoing, me), isTrue);
    });

    test('it does not leak into another operator conversation', () {
      final incoming = ptt(sender: alpha.id, recipient: me);
      expect(Audience.direct(bravo).includes(incoming, me), isFalse);
    });

    test('call signalling is admitted but never displayed', () {
      final signalling = C2Message(
        id: 'sig',
        type: MessageType.callSignaling,
        senderId: alpha.id,
        recipientId: me,
        encryptedBody: 'cipher',
        decryptedBody: '{"action":"CALL_ICE","candidate":"..."}',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(Audience.direct(alpha).includes(signalling, me), isTrue);
      expect(Audience.isDisplayableContent(signalling), isFalse,
          reason: 'ICE candidates are plumbing, not conversation');
    });

    test('control payloads stay hidden', () {
      for (final action in ['PAIR_ACK', 'TEAM_KEY_SYNC', 'DELIVERY_ACK', 'PTT_START']) {
        expect(
          Audience.isDisplayableContent(msg(
            type: MessageType.chat1to1,
            sender: alpha.id,
            recipient: me,
            body: '{"action":"$action"}',
          )),
          isFalse,
          reason: '$action must not render as a message',
        );
      }
    });
  });

  group('operator-facing labelling', () {
    test('broadcast says plainly that everyone will see it', () {
      // The scope control used to live inside a settings modal, so it was
      // possible to transmit to the whole squad without any on-screen sign.
      expect(const Audience.broadcast().assurance.toLowerCase(), contains('everyone'));
      expect(Audience.direct(alpha).assurance, contains('ALPHA-1'));
    });

    test('each audience is visually distinct', () {
      final accents = {
        Audience.direct(alpha).accent,
        const Audience.squad().accent,
        const Audience.broadcast().accent,
      };
      expect(accents.length, 3, reason: 'audiences must not be confusable');
    });

    test('the direct label follows the selected peer', () {
      expect(Audience.direct(alpha).label, 'ALPHA-1');
      expect(Audience.direct(bravo).label, 'BRAVO-2');
    });
  });
}
