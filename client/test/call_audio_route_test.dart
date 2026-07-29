import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/e2ee_engine.dart';
import 'package:vector_c2/crypto/group_engine.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/services/mesh_client.dart';
import 'package:vector_c2/services/p2p_mesh_engine.dart';
import 'package:vector_c2/services/secure_channel.dart';
import 'package:vector_c2/services/webrtc_call_service.dart';

/// Where call audio comes out of.
///
/// A voice call must default to the earpiece, like any phone. It was coming up
/// on the loudspeaker because the shell kept its own flag hardcoded to true and
/// handed that to the call screen, overriding what the service had chosen.
void main() {
  // Helper.setSpeakerphoneOn goes through a platform channel. The service
  // catches its failure, but the binding must exist for the call to be made
  // at all rather than throwing before the try block.
  TestWidgetsFlutterBinding.ensureInitialized();

  late WebRtcCallService service;

  setUp(() async {
    final identity = await OperatorIdentity.forTesting();
    service = WebRtcCallService(
      channel: SecureChannel(
        identity: identity,
        pairwise: E2EEEngine(identity: identity),
        team: TeamGroupEngine(
          groupId: 'g',
          groupName: 'G',
          groupSecret: TeamGroupEngine.generateSecret(),
        ),
        lookupContact: (_) => null,
      ),
      meshClient: MeshClient(identity: identity, seedNodeUrls: const []),
      p2pMeshEngine: P2PMeshEngine(
        identity: identity,
        p2pPort: 19096,
        isPairedContact: (_) => false,
        announceEnabled: false,
      ),
    );
  });

  tearDown(() => service.dispose());

  test('audio starts on the earpiece, not the loudspeaker', () {
    expect(
      service.isSpeakerphone,
      isFalse,
      reason: 'a voice call held to the ear must not use the loudspeaker',
    );
  });

  test('the service owns the route, so the UI reflects reality', () async {
    // The screen renders from this, rather than a separate flag that could
    // disagree with what the audio layer was actually told.
    await service.setSpeakerphone(true);
    expect(service.isSpeakerphone, isTrue);

    await service.setSpeakerphone(false);
    expect(service.isSpeakerphone, isFalse);
  });

  test('a route change notifies listeners so the button updates', () async {
    var notifications = 0;
    final sub = service.renderersChanged.listen((_) => notifications++);

    await service.setSpeakerphone(true);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(notifications, greaterThan(0));
    await sub.cancel();
  });
}
