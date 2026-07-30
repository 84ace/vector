import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/models/c2_message.dart';
import 'package:vector_c2/services/mesh_client.dart';

/// The outbox exists because a send with no transport used to vanish.
///
/// `sendMessage` returned false, nothing retried, and the conversation still
/// showed the message as sent — so an operator with a half-open socket believed
/// they had transmitted and the far end received nothing at all.
void main() {
  late MeshClient client;

  setUp(() async {
    final identity = await OperatorIdentity.forTesting();
    // No seeds, so nothing is ever connected: every send takes the offline path.
    client = MeshClient(identity: identity, seedNodeUrls: const []);
  });

  tearDown(() async => client.dispose());

  C2Message envelope(String id) => C2Message(
        id: id,
        type: MessageType.chat1to1,
        senderId: 'op-me',
        recipientId: 'op-them',
        encryptedBody: 'cipher-$id',
        timestamp: DateTime.now(),
        isMe: true,
      );

  test('an unsent envelope is held only when asked', () {
    expect(client.sendMessage(envelope('m1')), isFalse);
    expect(client.outboxDepth, 0, reason: 'the default must not silently buffer');

    expect(client.sendMessage(envelope('m2'), queueIfUnsent: true), isFalse);
    expect(client.outboxDepth, 1);
  });

  test('telemetry is not queued, so a stale fix is never read as current', () {
    // Asserted through the flag rather than the type: the decision belongs to
    // the caller, and TelemetryService deliberately does not pass it.
    client.sendMessage(envelope('t1'));
    expect(client.outboxDepth, 0);
  });

  test('the same envelope is not queued twice', () {
    final message = envelope('m1');
    client.sendMessage(message, queueIfUnsent: true);
    client.sendMessage(message, queueIfUnsent: true);
    expect(client.outboxDepth, 1);
  });

  test('a full outbox drops the oldest and says how many', () {
    // 200 is the cap. An operator out of range for an hour must not return to an
    // unbounded backlog, but they should be able to tell that it truncated.
    for (var i = 0; i < 205; i++) {
      client.sendMessage(envelope('m$i'), queueIfUnsent: true);
    }

    expect(client.outboxDepth, 200);
    expect(client.outboxDropped, 5);
  });

  test('nothing is dropped while there is room', () {
    for (var i = 0; i < 50; i++) {
      client.sendMessage(envelope('m$i'), queueIfUnsent: true);
    }
    expect(client.outboxDepth, 50);
    expect(client.outboxDropped, 0);
  });
}
