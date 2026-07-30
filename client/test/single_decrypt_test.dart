import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/e2ee_engine.dart';
import 'package:vector_c2/crypto/group_engine.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/models/c2_message.dart';
import 'package:vector_c2/models/operator_profile.dart';
import 'package:vector_c2/services/secure_channel.dart';

/// An envelope must be opened exactly once.
///
/// This is the invariant that broke every call and every cross-device
/// push-to-talk transmission, and it did so silently. Push-to-talk clips and
/// WebRTC signalling share [MessageType.callSignaling], and two independent
/// subscribers each held their own stream subscription and called
/// `channel.open()` on every one of them: the main receive path, to handle
/// SDP and ICE, and PttAudioService, to test the body for 'PTT_'.
///
/// The Double Ratchet consumes a message key on the first successful decrypt,
/// by design — that is what makes a replayed ciphertext unopenable. So the
/// second consumer always failed with "message key already used (replay or
/// duplicate)", and dropped the message. Every call and every transmission
/// between two devices failed, on sessions that were otherwise perfectly
/// healthy, and no amount of re-pairing or clearing data could help because
/// nothing was actually corrupt.
///
/// The receive path now opens each envelope once and dispatches the plaintext.
/// These tests pin the property that makes that mandatory.
void main() {
  // Ratchet state persists through platform channels; without the binding the
  // engine logs a failure for every message and the output buries the result.
  TestWidgetsFlutterBinding.ensureInitialized();

  late OperatorIdentity aliceId;
  late OperatorIdentity bobId;
  late SecureChannel alice;
  late SecureChannel bob;
  late OperatorProfile aliceProfile;
  late OperatorProfile bobProfile;

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

  setUp(() async {
    aliceId = await OperatorIdentity.forTesting();
    bobId = await OperatorIdentity.forTesting();
    aliceProfile = profileFor(aliceId, 'ALPHA');
    bobProfile = profileFor(bobId, 'BRAVO');

    final team = TeamGroupEngine(
      groupId: 'grp',
      groupName: 'TEST',
      groupSecret: TeamGroupEngine.generateSecret(),
    );

    alice = SecureChannel(
      identity: aliceId,
      pairwise: E2EEEngine(identity: aliceId),
      team: team,
      lookupContact: (id) => id == bobId.operatorId ? bobProfile : null,
    );
    bob = SecureChannel(
      identity: bobId,
      pairwise: E2EEEngine(identity: bobId),
      team: team,
      lookupContact: (id) => id == aliceId.operatorId ? aliceProfile : null,
    );
  });

  Future<C2Message> sealSignalling(String plaintext) => alice.sealDirect(
        type: MessageType.callSignaling,
        recipient: bobProfile,
        plaintext: plaintext,
        idPrefix: 'call',
      );

  test('a second decrypt of the same envelope always fails', () async {
    // The whole reason the receive path may have only one decrypt site. This is
    // correct, deliberate behaviour — it is what stops a captured ciphertext
    // being replayed — so the fix has to be "open it once", never "make the
    // ratchet tolerate a second open".
    final envelope = await sealSignalling('{"action":"CALL_OFFER"}');

    final first = await bob.open(envelope);
    expect(first, isA<OpenedMessage>(),
        reason: 'the first consumer decrypts it');

    final second = await bob.open(envelope);
    expect(second, isA<RejectedMessage>(),
        reason: 'a second consumer of the same envelope gets nothing, and the '
            'message is lost — which is exactly how calls and PTT failed');
  });

  test('signalling and push-to-talk share one message type', () async {
    // Why one subscriber could not simply filter the other out by type: both
    // travel as callSignaling, so the only way to tell them apart is to read the
    // plaintext — which costs the single decrypt.
    final sdp = await sealSignalling('{"action":"CALL_OFFER","sdp":"v=0"}');
    final ptt = await sealSignalling('PTT_STOP:${jsonEncode({
          'action': 'PTT_STOP',
          'audio_base64': 'AAAA',
          'duration_ms': 1200,
          'callsign': 'ALPHA',
        })}');

    expect(sdp.type, MessageType.callSignaling);
    expect(ptt.type, MessageType.callSignaling);

    final openedSdp = await bob.open(sdp);
    final openedPtt = await bob.open(ptt);

    expect(openedSdp, isA<OpenedMessage>());
    expect(openedPtt, isA<OpenedMessage>());

    // Both are distinguishable only after decryption, from the plaintext.
    expect((openedSdp as OpenedMessage).plaintext.contains('PTT_'), isFalse);
    expect((openedPtt as OpenedMessage).plaintext.startsWith('PTT_STOP:'), isTrue);
  });

  test('a whole call\'s signalling survives when opened once each', () async {
    // An offer plus its ICE candidates, in the order and volume a real call
    // produces. Every one must open — this is what failed in the field, where
    // all six envelopes of two call attempts were refused.
    final envelopes = [
      await sealSignalling('{"action":"CALL_OFFER","sdp":"v=0"}'),
      for (var i = 0; i < 5; i++)
        await sealSignalling('{"action":"ICE_CANDIDATE","index":$i}'),
    ];

    for (final envelope in envelopes) {
      expect(await bob.open(envelope), isA<OpenedMessage>(),
          reason: 'envelope ${envelope.id} must open on its single consumer');
    }
  });
}
