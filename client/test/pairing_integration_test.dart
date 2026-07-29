import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/e2ee_engine.dart';
import 'package:vector_c2/crypto/group_engine.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/models/c2_message.dart';
import 'package:vector_c2/models/operator_profile.dart';
import 'package:vector_c2/models/telemetry.dart';
import 'package:vector_c2/services/p2p_mesh_engine.dart';
import 'package:vector_c2/services/secure_channel.dart';

/// Two full stacks, real sockets, real crypto — the test that was missing.
///
/// Every bug in the pairing path so far survived unit testing and only showed
/// up between two devices: the admission rule that refused the very message
/// pairing depends on, the request sent before any link existed, and the team
/// key exchange that only ran in one direction. Each of those is reproduced
/// here against the actual [P2PMeshEngine] rather than a stand-in.
///
/// Verified to fail against the original defects: restoring the unpaired-link
/// refusal makes the pairing case time out waiting for a request that can never
/// arrive.
class _Node {
  final String callsign;
  final OperatorIdentity identity;
  final TeamGroupEngine team;
  late final SecureChannel channel;
  late final P2PMeshEngine p2p;

  /// Contacts this node has paired with, keyed by operator ID.
  final Map<String, OperatorProfile> contacts = {};

  /// Operators we have an outstanding pairing request to.
  final Set<String> pendingRequests = {};

  final List<C2Message> received = [];
  StreamSubscription? _sub;

  _Node._(this.callsign, this.identity, this.team);

  static Future<_Node> create(String callsign, int port) async {
    final identity = await OperatorIdentity.forTesting();
    final team = TeamGroupEngine(
      groupId: 'grp-test',
      groupName: 'TEST',
      groupSecret: TeamGroupEngine.generateSecret(),
    );

    final node = _Node._(callsign, identity, team);
    node.channel = SecureChannel(
      identity: identity,
      pairwise: E2EEEngine(identity: identity),
      team: team,
      lookupContact: (id) => node.contacts[id],
    );
    node.p2p = P2PMeshEngine(
      identity: identity,
      p2pPort: port,
      isPairedContact: (id) => node.contacts.containsKey(id),
      announceEnabled: false, // Deterministic: dial explicitly, no broadcasts.
    );

    await node.p2p.start();
    node._sub = node.p2p.incomingP2PMessages.listen(node.received.add);
    return node;
  }

  OperatorProfile get profile => OperatorProfile(
        id: identity.operatorId,
        callsign: callsign,
        name: callsign,
        role: OperatorRole.operator,
        avatarBase64: '',
        signPublicKey: identity.signPublicKey,
        kexPublicKey: identity.kexPublicKey,
        lastSeen: DateTime.now(),
      );

  /// Everything the QR code carries, consumed out of band.
  Map<String, dynamic> pairingPayload() => channel.pairingPayload(profile, 'tok-test');

  Future<void> dispose() async {
    await _sub?.cancel();
    await p2p.dispose();
  }

  Future<C2Message> waitFor(bool Function(C2Message) match, {String? because}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      for (final m in received) {
        if (match(m)) return m;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw StateError('timed out waiting for ${because ?? 'a message'} on $callsign');
  }
}

void main() {
  // The binding is needed for the secure-storage platform channel, but it also
  // installs HttpOverrides that would intercept WebSocket.connect. Clearing the
  // override keeps real sockets, which is the entire point of this suite.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final fakeSecureStore = <String, String>{};

  late _Node alpha;
  late _Node bravo;

  setUp(() async {
    fakeSecureStore.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        switch (call.method) {
          case 'write':
            fakeSecureStore[call.arguments['key'] as String] =
                call.arguments['value'] as String;
            return null;
          case 'read':
            return fakeSecureStore[call.arguments['key'] as String];
          case 'delete':
            fakeSecureStore.remove(call.arguments['key'] as String);
            return null;
          default:
            return null;
        }
      },
    );

    alpha = await _Node.create('ALPHA-1', 19090);
    bravo = await _Node.create('BRAVO-2', 19091);
  });

  tearDown(() async {
    await alpha.dispose();
    await bravo.dispose();
  });

  test('a full pairing converges both sides and telemetry flows', () async {
    // --- 1. Link comes up before anyone is a contact of anyone.
    final linked = await alpha.p2p.connectToPeer(address: '127.0.0.1', port: 19091);
    expect(linked, isTrue, reason: 'mutual handshake between strangers must succeed');

    // --- 2. ALPHA scans BRAVO's code: stores the contact, sends a request.
    final scanned = SecureChannel.contactFromPairingPayload(bravo.pairingPayload());
    expect(scanned, isNotNull);
    alpha.contacts[scanned!.id] = scanned;
    alpha.pendingRequests.add(scanned.id);

    final request = await alpha.channel.sealPairRequest(
      recipientId: scanned.id,
      me: alpha.profile,
      tokenId: 'tok-test',
    );
    expect(alpha.p2p.sendP2PDirectMessage(request), isTrue);

    // --- 3. BRAVO receives it despite ALPHA being a stranger. This is the
    // admission rule that originally refused the only message that matters.
    final inbound = await bravo.waitFor(
      (m) => m.type == MessageType.pairRequest,
      because: 'the pairing request',
    );
    final applicant = await bravo.channel.openPairRequest(inbound);
    expect(applicant, isNotNull, reason: 'request must verify against its signer');
    expect(applicant!.id, alpha.identity.operatorId);

    // --- 4. BRAVO approves: stores ALPHA, returns its team secret.
    bravo.contacts[applicant.id] = applicant;
    final bravoSecretBefore = bravo.team.groupSecret;

    final ack = await bravo.channel.sealDirect(
      type: MessageType.chat1to1,
      recipient: applicant,
      plaintext: jsonEncode({
        'action': 'PAIR_ACK',
        'group_secret': bravo.team.groupSecret,
        'group_epoch': bravo.team.epoch,
      }),
    );
    expect(bravo.p2p.sendP2PDirectMessage(ack), isTrue);

    // --- 5. ALPHA merges, then returns the result. Without this leg the two
    // sides diverge whenever ALPHA already held the lower secret.
    final ackMsg = await alpha.waitFor(
      (m) => m.type == MessageType.chat1to1,
      because: 'the pairing ack',
    );
    final ackPayload = await alpha.channel.openControlPayload(ackMsg);
    expect(ackPayload, isNotNull);
    expect(ackPayload!['action'], 'PAIR_ACK');
    expect(alpha.pendingRequests.remove(alpha.contacts.keys.first), isTrue);

    await alpha.team.mergeWithPeerSecret(
      ackPayload['group_secret'] as String,
      ackPayload['group_epoch'] as int,
    );

    final sync = await alpha.channel.sealDirect(
      type: MessageType.chat1to1,
      recipient: scanned,
      plaintext: jsonEncode({
        'action': 'TEAM_KEY_SYNC',
        'group_secret': alpha.team.groupSecret,
        'group_epoch': alpha.team.epoch,
      }),
    );
    expect(alpha.p2p.sendP2PDirectMessage(sync), isTrue);

    final syncMsg = await bravo.waitFor(
      (m) => m.type == MessageType.chat1to1 && m.id != ackMsg.id,
      because: 'the team key sync',
    );
    final syncPayload = await bravo.channel.openControlPayload(syncMsg);
    expect(syncPayload!['action'], 'TEAM_KEY_SYNC');
    await bravo.team.mergeWithPeerSecret(
      syncPayload['group_secret'] as String,
      syncPayload['group_epoch'] as int,
    );

    // --- 6. Both sides now hold the same team key.
    expect(
      alpha.team.groupSecret,
      bravo.team.groupSecret,
      reason: 'team keys must converge regardless of which sorted lower',
    );
    expect(
      [alpha.team.groupSecret, bravoSecretBefore].contains(bravo.team.groupSecret),
      isTrue,
      reason: 'the settled key must be one of the two originals',
    );

    // --- 7. Telemetry sealed by ALPHA opens on BRAVO.
    final position = Telemetry(
      operatorId: alpha.identity.operatorId,
      latitude: -33.8688,
      longitude: 151.2093,
      altitude: 12,
      speed: 0,
      heading: 90,
      accuracy: 5,
      batteryLevel: 82,
      isCharging: false,
      networkType: NetworkType.wifi,
      cellularSignalBars: 0,
      wifiSSID: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

    final telemetry = await alpha.channel.sealTeam(
      type: MessageType.telemetry,
      plaintext: jsonEncode(position.toJson()),
    );
    expect(alpha.p2p.sendP2PDirectMessage(telemetry), isTrue);

    final teleMsg = await bravo.waitFor(
      (m) => m.type == MessageType.telemetry,
      because: 'telemetry',
    );
    final opened = await bravo.channel.open(teleMsg);
    expect(opened, isA<OpenedMessage>(), reason: 'telemetry must decrypt after pairing');

    final decoded = Telemetry.fromJson(
      jsonDecode((opened as OpenedMessage).plaintext) as Map<String, dynamic>,
    );
    expect(decoded.latitude, closeTo(-33.8688, 1e-9));
    expect(decoded.longitude, closeTo(151.2093, 1e-9));
    expect(opened.sender!.id, alpha.identity.operatorId);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('an unpaired stranger cannot inject anything but a pairing request', () async {
    await alpha.p2p.connectToPeer(address: '127.0.0.1', port: 19091);

    // ALPHA knows BRAVO (scanned the code); BRAVO does not know ALPHA yet.
    final scanned = SecureChannel.contactFromPairingPayload(bravo.pairingPayload())!;
    alpha.contacts[scanned.id] = scanned;

    final hostile = await alpha.channel.sealDirect(
      type: MessageType.chat1to1,
      recipient: scanned,
      plaintext: jsonEncode({'action': 'UNPAIR_AND_PURGE'}),
    );
    alpha.p2p.sendP2PDirectMessage(hostile);

    // Give it room to arrive if the guard were broken.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(
      bravo.received.where((m) => m.type == MessageType.chat1to1),
      isEmpty,
      reason: 'a stranger must not be able to deliver control messages',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));
}
