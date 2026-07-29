import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/e2ee_engine.dart';
import 'package:vector_c2/crypto/group_engine.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/models/c2_message.dart';
import 'package:vector_c2/models/operator_profile.dart';
import 'package:vector_c2/services/secure_channel.dart';
import 'package:vector_c2/services/team_key_distributor.dart';

/// Team key re-delivery.
///
/// The defect: rotation was one best-effort sweep. An operator who was offline
/// at that instant never received the new key, nothing ever tried again, and the
/// only trace was a log line. Their team traffic then failed to decrypt for as
/// long as the app kept running.
///
/// These tests drive the real SecureChannel over real key agreement on both
/// ends, so a rekey that "sent" but cannot actually be opened by the recipient
/// counts as a failure here.
void main() {
  // TeamGroupEngine.rotate() persists the new secret to the platform keychain,
  // which does not exist under `flutter test`.
  TestWidgetsFlutterBinding.ensureInitialized();

  final fakeSecureStore = <String, String>{};

  setUp(() {
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
  });

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

  /// A complete crypto stack for one operator, as main.dart assembles it.
  Future<
      ({
        OperatorIdentity identity,
        OperatorProfile profile,
        TeamGroupEngine team,
        SecureChannel channel,
      })> stack(String callsign, List<OperatorProfile> contacts) async {
    final identity = await OperatorIdentity.forTesting();
    final profile = profileFor(identity, callsign);
    final team = TeamGroupEngine(
      groupId: 'grp-test',
      groupName: 'TEST',
      groupSecret: TeamGroupEngine.generateSecret(),
    );
    final channel = SecureChannel(
      identity: identity,
      pairwise: E2EEEngine(identity: identity),
      team: team,
      lookupContact: (id) {
        for (final c in contacts) {
          if (c.id == id) return c;
        }
        return null;
      },
    );
    return (identity: identity, profile: profile, team: team, channel: channel);
  }

  group('delivery is confirmed, not assumed', () {
    test('an unreachable operator stays pending after a failed sweep', () async {
      final contacts = <OperatorProfile>[];
      final me = await stack('ALPHA', contacts);
      final peerIdentity = await OperatorIdentity.forTesting();
      final peer = profileFor(peerIdentity, 'BRAVO');
      contacts.add(peer);

      var online = false;
      final persisted = <Set<String>>[];

      final distributor = TeamKeyDistributor(
        sendRekey: (_) async => online,
        lookupContact: (id) => id == peer.id ? peer : null,
        currentEpoch: () => me.team.epoch,
        persist: (p) async => persisted.add(Set.of(p)),
      );
      addTearDown(distributor.dispose);

      await me.team.rotate();
      final report = await distributor.distributeToAll([peer]);

      expect(report.delivered, 0);
      expect(report.isComplete, isFalse);
      expect(distributor.pending, {peer.id});
      expect(persisted.last, {peer.id},
          reason: 'the obligation must survive a restart');

      // The peer reappears. This is the mechanism that was missing entirely.
      online = true;
      final retry = await distributor.sweep();
      expect(retry.delivered, 1);

      // Still pending: a transport accepting the envelope is not the peer
      // holding the key.
      expect(distributor.pending, {peer.id});

      await distributor.acknowledge(peer.id, me.team.epoch);
      expect(distributor.pending, isEmpty);
      expect(persisted.last, isEmpty);
    });

    test('a send that succeeds does not by itself clear the obligation', () async {
      final peerIdentity = await OperatorIdentity.forTesting();
      final peer = profileFor(peerIdentity, 'BRAVO');
      final me = await stack('ALPHA', [peer]);

      final distributor = TeamKeyDistributor(
        sendRekey: (_) async => true, // transport always accepts
        lookupContact: (id) => id == peer.id ? peer : null,
        currentEpoch: () => me.team.epoch,
        persist: (_) async {},
      );
      addTearDown(distributor.dispose);

      await me.team.rotate();
      final report = await distributor.distributeToAll([peer]);

      expect(report.delivered, 1);
      expect(report.isComplete, isFalse,
          reason: 'nothing has been acknowledged yet');
      expect(distributor.pending, {peer.id});
    });
  });

  group('the rekey a retry sends is one the peer can actually open', () {
    test('a peer that was offline decrypts the key after reconnecting', () async {
      // The end-to-end property. Two full stacks; the rekey is sealed pairwise
      // by one and opened by the other, so a key that is delivered but
      // undecryptable fails this test.
      final aliceContacts = <OperatorProfile>[];
      final bobContacts = <OperatorProfile>[];
      final alice = await stack('ALPHA', aliceContacts);
      final bob = await stack('BRAVO', bobContacts);
      aliceContacts.add(bob.profile);
      bobContacts.add(alice.profile);

      // Start from a shared key, as pairing would leave them.
      await bob.team.adoptRekey(alice.team.groupSecret, alice.team.epoch + 1);
      await alice.team.adoptRekey(bob.team.groupSecret, bob.team.epoch);
      expect(alice.team.groupSecret, bob.team.groupSecret);

      var bobReachable = false;
      final inFlight = <String>[];

      final distributor = TeamKeyDistributor(
        sendRekey: (recipient) async {
          final envelope = await alice.channel.sealDirect(
            type: MessageType.chat1to1,
            recipient: recipient,
            plaintext: jsonEncode({
              'action': 'GROUP_REKEY',
              'group_secret': alice.team.groupSecret,
              'group_epoch': alice.team.epoch,
            }),
            idPrefix: 'rekey',
          );
          if (!bobReachable) return false;
          inFlight.add(jsonEncode(envelope.toEnvelopeJson()));
          return true;
        },
        lookupContact: (id) => id == bob.profile.id ? bob.profile : null,
        currentEpoch: () => alice.team.epoch,
        persist: (_) async {},
      );
      addTearDown(distributor.dispose);

      // Alice rotates while Bob is offline.
      await alice.team.rotate();
      final rotatedSecret = alice.team.groupSecret;
      final rotatedEpoch = alice.team.epoch;
      expect(bob.team.groupSecret, isNot(rotatedSecret));

      await distributor.distributeToAll([bob.profile]);
      expect(inFlight, isEmpty, reason: 'Bob was offline');
      expect(bob.team.groupSecret, isNot(rotatedSecret),
          reason: 'Bob must still be on the old key');

      // Bob comes back and the retry fires.
      bobReachable = true;
      await distributor.sweep();
      expect(inFlight, hasLength(1));

      // Bob opens it for real.
      final received = C2Message.fromEnvelopeJson(
        jsonDecode(inFlight.single) as Map<String, dynamic>,
        bob.profile.id,
      );
      final opened = await bob.channel.open(received);
      expect(opened, isA<OpenedMessage>(),
          reason: 'the retried rekey must verify and decrypt, not merely send');

      final payload = jsonDecode((opened as OpenedMessage).plaintext) as Map<String, dynamic>;
      expect(payload['action'], 'GROUP_REKEY');
      expect(
        await bob.team.adoptRekey(
          payload['group_secret'] as String,
          payload['group_epoch'] as int,
        ),
        isTrue,
      );
      expect(bob.team.groupSecret, rotatedSecret);
      expect(bob.team.epoch, rotatedEpoch);

      // And Bob's acknowledgement closes it out.
      expect(await distributor.acknowledge(bob.profile.id, bob.team.epoch), isTrue);
      expect(distributor.hasPending, isFalse);
    });
  });

  group('acknowledgement bookkeeping', () {
    test('a stale ack does not clear an obligation from a later rotation', () async {
      final peerIdentity = await OperatorIdentity.forTesting();
      final peer = profileFor(peerIdentity, 'BRAVO');
      final me = await stack('ALPHA', [peer]);

      final distributor = TeamKeyDistributor(
        sendRekey: (_) async => true,
        lookupContact: (id) => id == peer.id ? peer : null,
        currentEpoch: () => me.team.epoch,
        persist: (_) async {},
      );
      addTearDown(distributor.dispose);

      await me.team.rotate();
      final firstEpoch = me.team.epoch;
      await distributor.distributeToAll([peer]);

      // A second unpair rotates again before the first ack arrives.
      await me.team.rotate();
      await distributor.distributeToAll([peer]);

      expect(await distributor.acknowledge(peer.id, firstEpoch), isFalse,
          reason: 'confirming the superseded epoch leaves the peer behind');
      expect(distributor.pending, {peer.id});

      expect(await distributor.acknowledge(peer.id, me.team.epoch), isTrue);
      expect(distributor.pending, isEmpty);
    });

    test('an ack for a newer epoch is accepted', () async {
      // The peer already holds a key we have not caught up with. Refusing this
      // would retry forever against an operator who is ahead of us.
      final peerIdentity = await OperatorIdentity.forTesting();
      final peer = profileFor(peerIdentity, 'BRAVO');
      final me = await stack('ALPHA', [peer]);

      final distributor = TeamKeyDistributor(
        sendRekey: (_) async => true,
        lookupContact: (id) => id == peer.id ? peer : null,
        currentEpoch: () => me.team.epoch,
        persist: (_) async {},
      );
      addTearDown(distributor.dispose);

      await me.team.rotate();
      await distributor.distributeToAll([peer]);
      expect(await distributor.acknowledge(peer.id, me.team.epoch + 5), isTrue);
      expect(distributor.pending, isEmpty);
    });

    test('an ack from an operator who owes nothing changes nothing', () async {
      final me = await stack('ALPHA', []);
      final distributor = TeamKeyDistributor(
        sendRekey: (_) async => true,
        lookupContact: (_) => null,
        currentEpoch: () => me.team.epoch,
        persist: (_) async {},
      );
      addTearDown(distributor.dispose);

      expect(await distributor.acknowledge('op-stranger', 99), isFalse);
    });
  });

  group('housekeeping', () {
    test('unpairing during a pending rotation drops the obligation', () async {
      final peerIdentity = await OperatorIdentity.forTesting();
      final peer = profileFor(peerIdentity, 'BRAVO');
      final me = await stack('ALPHA', [peer]);

      var paired = true;
      final distributor = TeamKeyDistributor(
        sendRekey: (_) async => false,
        lookupContact: (id) => paired && id == peer.id ? peer : null,
        currentEpoch: () => me.team.epoch,
        persist: (_) async {},
      );
      addTearDown(distributor.dispose);

      await me.team.rotate();
      await distributor.distributeToAll([peer]);
      expect(distributor.pending, {peer.id});

      paired = false;
      await distributor.sweep();
      expect(distributor.pending, isEmpty,
          reason: 'a contact we unpaired from is owed nothing');
    });

    test('restore resumes obligations from a previous run', () async {
      final peerIdentity = await OperatorIdentity.forTesting();
      final peer = profileFor(peerIdentity, 'BRAVO');
      final me = await stack('ALPHA', [peer]);

      var sends = 0;
      final distributor = TeamKeyDistributor(
        sendRekey: (_) async {
          sends++;
          return true;
        },
        lookupContact: (id) => id == peer.id ? peer : null,
        currentEpoch: () => me.team.epoch,
        persist: (_) async {},
      );
      addTearDown(distributor.dispose);

      distributor.restore([peer.id]);
      expect(distributor.pending, {peer.id});

      await distributor.sweep();
      expect(sends, 1, reason: 'a rotation must outlive the process that ran it');
    });

    test('onRouteAvailable is what actually re-attempts delivery', () async {
      // main.dart calls this when the relay connects and when a P2P peer
      // appears. Those are the events the original code had no hook for.
      final peerIdentity = await OperatorIdentity.forTesting();
      final peer = profileFor(peerIdentity, 'BRAVO');
      final me = await stack('ALPHA', [peer]);

      var sends = 0;
      final distributor = TeamKeyDistributor(
        sendRekey: (_) async {
          sends++;
          return true;
        },
        lookupContact: (id) => id == peer.id ? peer : null,
        currentEpoch: () => me.team.epoch,
        persist: (_) async {},
      );
      addTearDown(distributor.dispose);

      distributor.restore([peer.id]);
      distributor.onRouteAvailable();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sends, 1);

      // With nothing pending it must stay quiet rather than re-sending keys on
      // every reconnect for the rest of the session.
      await distributor.acknowledge(peer.id, me.team.epoch);
      distributor.onRouteAvailable();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sends, 1);
    });

    test('concurrent sweeps do not double-send', () async {
      // The relay reconnecting and a P2P peer appearing can land in the same
      // instant; without the guard each recipient got two keys.
      final peerIdentity = await OperatorIdentity.forTesting();
      final peer = profileFor(peerIdentity, 'BRAVO');
      final me = await stack('ALPHA', [peer]);

      var sends = 0;
      final distributor = TeamKeyDistributor(
        sendRekey: (_) async {
          sends++;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return true;
        },
        lookupContact: (id) => id == peer.id ? peer : null,
        currentEpoch: () => me.team.epoch,
        persist: (_) async {},
      );
      addTearDown(distributor.dispose);

      distributor.restore([peer.id]);
      await Future.wait([distributor.sweep(), distributor.sweep()]);
      expect(sends, 1);
    });
  });
}
