import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/e2ee_engine.dart';
import 'package:vector_c2/crypto/group_engine.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/models/c2_message.dart';
import 'package:vector_c2/models/operator_profile.dart';
import 'package:vector_c2/services/mesh_client.dart';
import 'package:vector_c2/services/secure_channel.dart';

/// End-to-end test against a real relay node.
///
/// Run the node first, then:
///   RELAY_URL=http://127.0.0.1:18080 flutter test test/live_relay_test.dart
///
/// Skipped when RELAY_URL is unset so the default suite stays hermetic. This is
/// the only test that exercises the whole path at once — handshake, routing,
/// signing and sealing across both implementations.
void main() {
  final relayUrl = Platform.environment['RELAY_URL'];

  // Deliberately no TestWidgetsFlutterBinding here: it installs an HttpOverrides
  // that fails every real request, and this suite needs genuine sockets. Nothing
  // under test touches secure storage — identities are ephemeral and the team
  // engine is constructed directly.

  OperatorProfile profileFor(OperatorIdentity id, String callsign) => OperatorProfile(
        id: id.operatorId,
        callsign: callsign,
        name: callsign,
        role: OperatorRole.operator,
        avatarBase64: '',
        signPublicKey: id.signPublicKey,
        kexPublicKey: id.kexPublicKey,
        lastSeen: DateTime.now(),
      );

  test('two clients exchange a sealed message through a live relay', () async {
    final alice = await OperatorIdentity.forTesting();
    final bob = await OperatorIdentity.forTesting();

    final aliceClient = MeshClient(identity: alice, seedNodeUrls: [relayUrl!]);
    final bobClient = MeshClient(identity: bob, seedNodeUrls: [relayUrl]);

    final aliceUp = aliceClient.connectionState.firstWhere((c) => c);
    final bobUp = bobClient.connectionState.firstWhere((c) => c);

    aliceClient.start();
    bobClient.start();

    await aliceUp.timeout(const Duration(seconds: 15));
    await bobUp.timeout(const Duration(seconds: 15));

    final aliceChannel = SecureChannel(
      identity: alice,
      pairwise: E2EEEngine(identity: alice),
      team: TeamGroupEngine(
          groupId: 'g', groupName: 'G', groupSecret: TeamGroupEngine.generateSecret()),
      lookupContact: (_) => profileFor(bob, 'BRAVO'),
    );
    final bobChannel = SecureChannel(
      identity: bob,
      pairwise: E2EEEngine(identity: bob),
      team: TeamGroupEngine(
          groupId: 'g', groupName: 'G', groupSecret: TeamGroupEngine.generateSecret()),
      lookupContact: (_) => profileFor(alice, 'ALPHA'),
    );

    final inbound = bobClient.incomingMessages.first;

    final sealed = await aliceChannel.sealDirect(
      type: MessageType.chat1to1,
      recipient: profileFor(bob, 'BRAVO'),
      plaintext: 'rally at grid 41-72',
    );
    expect(aliceClient.sendMessage(sealed), isTrue);

    final received = await inbound.timeout(const Duration(seconds: 10));

    // The relay stamped the authenticated sender, and the body is still opaque.
    expect(received.senderId, alice.operatorId);
    expect(received.encryptedBody, isNot(contains('rally')));

    final opened = await bobChannel.open(received);
    expect(opened, isA<OpenedMessage>());
    expect((opened as OpenedMessage).plaintext, 'rally at grid 41-72');

    await aliceClient.dispose();
    await bobClient.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)), skip: relayUrl == null ? 'RELAY_URL not set' : null);

  test('the relay refuses a client that cannot sign its challenge', () async {
    final uri = Uri.parse(relayUrl!);
    final socket = await WebSocket.connect(
      'ws://${uri.host}:${uri.port}/ws',
    ).timeout(const Duration(seconds: 10));

    final frames = StreamQueue<dynamic>(socket);

    final challenge = jsonDecode(await frames.next as String) as Map<String, dynamic>;
    expect(challenge['type'], 'AUTH_CHALLENGE');

    // Present a real key with a garbage signature.
    final impostor = await OperatorIdentity.forTesting();
    socket.add(jsonEncode({
      'type': 'AUTH_RESPONSE',
      'operator_id': impostor.operatorId,
      'sign_key': impostor.signPublicKey,
      'signature': base64Encode(List<int>.filled(64, 0)),
    }));

    final result = jsonDecode(await frames.next as String) as Map<String, dynamic>;
    expect(result['type'], 'AUTH_RESULT');
    expect(result['ok'], isFalse);

    await frames.cancel();
    await socket.close();
  }, timeout: const Timeout(Duration(seconds: 30)), skip: relayUrl == null ? 'RELAY_URL not set' : null);
}

/// Minimal pull-based queue over a single-subscription stream.
class StreamQueue<T> {
  final List<T> _buffered = [];
  final List<Completer<T>> _waiting = [];
  late final StreamSubscription<T> _sub;

  StreamQueue(Stream<T> stream) {
    _sub = stream.listen((event) {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(event);
      } else {
        _buffered.add(event);
      }
    });
  }

  Future<T> get next {
    if (_buffered.isNotEmpty) return Future.value(_buffered.removeAt(0));
    final completer = Completer<T>();
    _waiting.add(completer);
    return completer.future;
  }

  Future<void> cancel() => _sub.cancel();
}
