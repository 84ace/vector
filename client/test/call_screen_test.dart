import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/e2ee_engine.dart';
import 'package:vector_c2/crypto/group_engine.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/models/operator_profile.dart';
import 'package:vector_c2/services/mesh_client.dart';
import 'package:vector_c2/services/p2p_mesh_engine.dart';
import 'package:vector_c2/services/secure_channel.dart';
import 'package:vector_c2/services/webrtc_call_service.dart';
import 'package:vector_c2/ui/chat/call_screen.dart';

/// Layout coverage for the call UI, which was previously unreachable by tests:
/// it lived inside CallView alongside push-to-talk, the clip strip and the
/// audio settings, none of which a call screen needs.
void main() {
  late WebRtcCallService service;
  late OperatorProfile peer;

  setUp(() async {
    final identity = await OperatorIdentity.forTesting();
    final channel = SecureChannel(
      identity: identity,
      pairwise: E2EEEngine(identity: identity),
      team: TeamGroupEngine(
        groupId: 'g',
        groupName: 'G',
        groupSecret: TeamGroupEngine.generateSecret(),
      ),
      lookupContact: (_) => null,
    );

    service = WebRtcCallService(
      channel: channel,
      meshClient: MeshClient(identity: identity, seedNodeUrls: const []),
      p2pMeshEngine: P2PMeshEngine(
        identity: identity,
        p2pPort: 19099,
        isPairedContact: (_) => false,
        announceEnabled: false,
      ),
    );

    peer = OperatorProfile(
      id: 'op-bravo',
      callsign: 'BRAVO-2',
      name: 'BRAVO-2',
      role: OperatorRole.operator,
      avatarBase64: '',
      signPublicKey: 'sign',
      kexPublicKey: 'kex',
      lastSeen: DateTime.now(),
    );
  });

  Future<void> pump(WidgetTester tester, {int seconds = 0, Size? size}) async {
    if (size != null) {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }

    await tester.pumpWidget(
      MaterialApp(
        home: CallScreen(
          service: service,
          fallbackPeer: peer,
          callDurationSecs: seconds,
          useLoudspeaker: true,
          onLoudspeakerChanged: (_) {},
          onHangUp: () {},
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the dialling screen renders and names the peer', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('BRAVO-2'), findsOneWidget);
  });

  testWidgets('it renders on a small phone without overflowing', (tester) async {
    // Fixed-height boxes in this file have overflowed twice before.
    await pump(tester, size: const Size(320, 568));
    expect(tester.takeException(), isNull);
  });

  testWidgets('it renders on a large phone', (tester) async {
    await pump(tester, size: const Size(430, 932));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long call duration still lays out', (tester) async {
    await pump(tester, seconds: 359999, size: const Size(320, 568));
    expect(tester.takeException(), isNull);
  });

  tearDown(() async {
    await service.dispose();
  });
}
