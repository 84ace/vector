import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/models/c2_message.dart';
import 'package:vector_c2/models/operator_profile.dart';
import 'package:vector_c2/models/telemetry.dart';
import 'package:vector_c2/crypto/e2ee_engine.dart';
import 'package:vector_c2/crypto/group_engine.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/services/mesh_client.dart';
import 'package:vector_c2/services/p2p_mesh_engine.dart';
import 'package:vector_c2/services/ptt_recorder.dart';
import 'package:vector_c2/services/secure_channel.dart';
import 'package:vector_c2/ui/chat/audience_selector.dart';
import 'package:vector_c2/ui/comms/conversation_list.dart';

void main() {
  late PttRecorder recorder;

  setUp(() async {
    final identity = await OperatorIdentity.forTesting();
    final me = OperatorProfile(
      id: identity.operatorId,
      callsign: 'ME',
      name: 'ME',
      role: OperatorRole.operator,
      avatarBase64: '',
      signPublicKey: identity.signPublicKey,
      kexPublicKey: identity.kexPublicKey,
      lastSeen: DateTime.now(),
    );
    recorder = PttRecorder(
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
        p2pPort: 19098,
        isPairedContact: (_) => false,
        announceEnabled: false,
      ),
      myProfile: me,
    );
  });

  OperatorProfile op(String id, String callsign) => OperatorProfile(
        id: id,
        callsign: callsign,
        name: callsign,
        role: OperatorRole.operator,
        avatarBase64: '',
        signPublicKey: 'sign-$id',
        kexPublicKey: 'kex-$id',
        lastSeen: DateTime.now(),
      );

  Telemetry position({required Duration age, Duration? interval}) => Telemetry(
        operatorId: 'op-a',
        latitude: 1,
        longitude: 2,
        altitude: 0,
        speed: 0,
        heading: 0,
        accuracy: 5,
        batteryLevel: 80,
        isCharging: false,
        networkType: NetworkType.wifi,
        cellularSignalBars: 0,
        wifiSSID: '',
        timestamp: DateTime.now().subtract(age),
        reportInterval: interval ?? const Duration(minutes: 10),
      );

  C2Message text(String body, {bool mine = false}) => C2Message(
        id: 'm-$body',
        type: MessageType.chat1to1,
        senderId: mine ? 'op-me' : 'op-a',
        recipientId: mine ? 'op-a' : 'op-me',
        encryptedBody: 'cipher',
        decryptedBody: body,
        timestamp: DateTime.now().subtract(const Duration(minutes: 2)),
        isMe: mine,
      );

  Future<void> pump(
    WidgetTester tester,
    List<ConversationSummary> rows, {
    Size? size,
    void Function(OperatorProfile peer, {bool lock})? onLocateOnMap,
  }) async {
    if (size != null) {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationList(
          conversations: rows,
          onOpen: (_) {},
          onShowDetails: (_) {},
          onAddOperator: () {},
          ptt: recorder,
          onVoiceRecorded: (_) async {},
          onStartCall: (_, _) {},
          onLocateOnMap: onLocateOnMap,
        ),
      ),
    );
    await tester.pump();
  }

  final alpha = op('op-a', 'ALPHA-1');

  testWidgets('shows an operator with their last message and status', (tester) async {
    await pump(tester, [
      ConversationSummary(
        audience: Audience.direct(alpha),
        telemetry: position(age: const Duration(minutes: 1)),
        lastMessage: text('rally at grid 41'),
        unread: 2,
      ),
      const ConversationSummary(audience: Audience.squad(), memberCount: 3),
      const ConversationSummary(audience: Audience.broadcast()),
    ]);

    expect(tester.takeException(), isNull);
    expect(find.text('ALPHA-1'), findsOneWidget);
    expect(find.text('rally at grid 41'), findsOneWidget);
    expect(find.text('REPORTING'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: 'unread badge');
    expect(find.text('SQUAD'), findsWidgets);
    expect(find.text('ALL'), findsOneWidget);
  });

  testWidgets('distinguishes overdue from lost from never-heard-from', (tester) async {
    await pump(tester, [
      ConversationSummary(
        audience: Audience.direct(op('op-a', 'OVERDUE-1')),
        telemetry: position(age: const Duration(minutes: 30)),
      ),
      ConversationSummary(
        audience: Audience.direct(op('op-b', 'LOST-2')),
        telemetry: position(age: const Duration(hours: 3)),
      ),
      ConversationSummary(audience: Audience.direct(op('op-c', 'SILENT-3'))),
    ]);

    expect(find.text('OVERDUE'), findsOneWidget);
    expect(find.text('LOST'), findsOneWidget);
    expect(find.text('NO POSITION'), findsOneWidget);
  });

  testWidgets('a voice clip previews as such, not as raw payload', (tester) async {
    await pump(tester, [
      ConversationSummary(
        audience: Audience.direct(alpha),
        lastMessage: text('PTT_STOP:{"audio_base64":"AAAA"}'),
      ),
    ]);

    expect(find.text('Voice clip'), findsOneWidget);
    expect(find.textContaining('audio_base64'), findsNothing);
  });

  testWidgets('offers pairing when the squad is empty', (tester) async {
    await pump(tester, const [
      ConversationSummary(audience: Audience.squad()),
      ConversationSummary(audience: Audience.broadcast()),
    ]);

    expect(find.text('NO OPERATORS PAIRED'), findsOneWidget);
    expect(find.text('ADD OPERATOR'), findsOneWidget);
  });

  testWidgets('shows range, battery and link for an operator', (tester) async {
    await pump(tester, [
      ConversationSummary(
        audience: Audience.direct(alpha),
        telemetry: position(age: const Duration(minutes: 1)),
        distanceMeters: 1500,
      ),
    ]);

    expect(find.text('1.5km'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('WIFI'), findsOneWidget);
    expect(find.text('±5m'), findsOneWidget);
  });

  testWidgets('range is shown in metres when close', (tester) async {
    await pump(tester, [
      ConversationSummary(
        audience: Audience.direct(alpha),
        telemetry: position(age: const Duration(minutes: 1)),
        distanceMeters: 240,
      ),
    ]);
    expect(find.text('240m'), findsOneWidget);
  });

  testWidgets('range is omitted when either end has no fix', (tester) async {
    await pump(tester, [
      ConversationSummary(
        audience: Audience.direct(alpha),
        telemetry: position(age: const Duration(minutes: 1)),
      ),
    ]);

    expect(find.byIcon(Icons.straighten), findsNothing);
    expect(find.text('80%'), findsOneWidget, reason: 'other stats still show');
  });

  testWidgets('no stats row at all without telemetry', (tester) async {
    await pump(tester, [ConversationSummary(audience: Audience.direct(alpha))]);
    expect(find.byIcon(Icons.straighten), findsNothing);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('offers all four actions on an operator row', (tester) async {
    // Push-to-talk was one tap away when it had its own page. Routing
    // everything through a conversation cost it that; the row restores it.
    await pump(tester, [ConversationSummary(audience: Audience.direct(alpha))]);

    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(find.byIcon(Icons.call), findsOneWidget);
    expect(find.byIcon(Icons.videocam), findsOneWidget);
  });

  testWidgets('channels offer message and voice but not calls', (tester) async {
    // There is no group calling, so offering it on a channel would promise
    // something that does not exist.
    await pump(tester, [
      ConversationSummary(audience: Audience.direct(alpha)),
      const ConversationSummary(audience: Audience.squad(), memberCount: 3),
      const ConversationSummary(audience: Audience.broadcast()),
    ]);

    // Message and push-to-talk on all three rows; calls only on the operator.
    expect(find.byIcon(Icons.chat_bubble_outline), findsNWidgets(3));
    expect(find.byIcon(Icons.mic_none), findsNWidgets(3));
    expect(find.byIcon(Icons.call), findsOneWidget);
    expect(find.byIcon(Icons.videocam), findsOneWidget);
  });

  testWidgets('a call action fires for the right operator', (tester) async {
    Audience? called;
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationList(
          conversations: [ConversationSummary(audience: Audience.direct(alpha))],
          onOpen: (_) {},
          onShowDetails: (_) {},
          onAddOperator: () {},
          ptt: recorder,
          onVoiceRecorded: (_) async {},
          onStartCall: (a, _) => called = a,
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.call));
    await tester.pump();
    expect(called, Audience.direct(alpha));
  });

  testWidgets('holding push-to-talk keeps transmitting past the long-press deadline',
      (tester) async {
    // Regression: the control's own Tooltip registered a long-press recogniser
    // on the same pointer, and at the 500 ms deadline it won the gesture arena
    // and rejected the press this widget was waiting on. Transmissions died
    // half a second in, or never started at all.
    await pump(tester, [ConversationSummary(audience: Audience.direct(alpha))]);

    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic_none)));
    addTearDown(() async => gesture.up());

    await tester.pump(const Duration(milliseconds: 600));
    expect(
      recorder.activeAudience.value,
      Audience.direct(alpha),
      reason: 'the long press should have opened the microphone by now',
    );

    await tester.pump(const Duration(seconds: 2));
    expect(
      recorder.activeAudience.value,
      Audience.direct(alpha),
      reason: 'nothing should stop the transmission while the finger is down',
    );
  });

  testWidgets('the locate control reports centre on tap and track on hold', (tester) async {
    final calls = <(String, bool)>[];
    await pump(
      tester,
      [
        ConversationSummary(
          audience: Audience.direct(alpha),
          telemetry: position(age: const Duration(minutes: 1)),
        ),
      ],
      onLocateOnMap: (peer, {bool lock = false}) => calls.add((peer.callsign, lock)),
    );

    expect(find.byIcon(Icons.my_location), findsOneWidget);

    await tester.tap(find.byIcon(Icons.my_location));
    await tester.pump();
    expect(calls, [('ALPHA-1', false)]);

    await tester.longPress(find.byIcon(Icons.my_location));
    await tester.pump();
    expect(calls.last, ('ALPHA-1', true));
  });

  testWidgets('the locate control is disabled for an operator with no position',
      (tester) async {
    final calls = <String>[];
    await pump(
      tester,
      [ConversationSummary(audience: Audience.direct(alpha))],
      onLocateOnMap: (peer, {bool lock = false}) => calls.add(peer.callsign),
    );

    // Shown but visibly inert, rather than absent: a control that comes and goes
    // between rows moves the other actions under the operator's thumb.
    expect(find.byIcon(Icons.location_disabled), findsOneWidget);
    await tester.longPress(find.byIcon(Icons.location_disabled));
    await tester.pump();
    expect(calls, isEmpty, reason: 'tracking needs a position to track');
  });

  testWidgets('no locate control when the map cannot be reached', (tester) async {
    await pump(tester, [ConversationSummary(audience: Audience.direct(alpha))]);
    expect(find.byIcon(Icons.my_location), findsNothing);
    expect(find.byIcon(Icons.location_disabled), findsNothing);
  });

  testWidgets('rows with actions still fit a small phone', (tester) async {
    await pump(
      tester,
      [
        ConversationSummary(
          audience: Audience.direct(op('op-a', 'OVERWATCH-ACTUAL-LONG-7')),
          telemetry: position(age: const Duration(minutes: 1)),
          lastMessage: text('a considerably longer message than fits on a line'),
          unread: 99,
        ),
      ],
      size: const Size(320, 568),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('lays out on a small phone with a long callsign', (tester) async {
    await pump(
      tester,
      [
        ConversationSummary(
          audience: Audience.direct(op('op-a', 'OVERWATCH-ACTUAL-LONG-7')),
          telemetry: position(age: const Duration(minutes: 1)),
          lastMessage: text('a considerably longer message than will fit on one line'),
          unread: 99,
        ),
      ],
      size: const Size(320, 568),
    );

    expect(tester.takeException(), isNull);
  });
}
