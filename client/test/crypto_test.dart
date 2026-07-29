import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/e2ee_engine.dart';
import 'package:vector_c2/crypto/group_engine.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/models/c2_message.dart';
import 'package:vector_c2/models/operator_profile.dart';
import 'package:vector_c2/models/telemetry.dart';
import 'package:vector_c2/services/secure_channel.dart';

/// Builds an in-memory identity without touching secure storage.
Future<OperatorIdentity> makeIdentity() => OperatorIdentity.forTesting();

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_secure_storage talks to the platform keychain, which does not exist
  // under `flutter test`. Back it with an in-memory map so persistence paths can
  // be exercised without loosening the production storage code.
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
          case 'readAll':
            return Map<String, String>.from(fakeSecureStore);
          case 'deleteAll':
            fakeSecureStore.clear();
            return null;
          default:
            return null;
        }
      },
    );
  });

  group('operator identity', () {
    test('operator ID is derived from the signing key', () async {
      final alice = await makeIdentity();
      expect(alice.operatorId, OperatorIdentity.deriveOperatorId(alice.signPublicKey));
      expect(alice.operatorId, startsWith('op-'));
    });

    test('two identities are distinct', () async {
      final a = await makeIdentity();
      final b = await makeIdentity();
      expect(a.operatorId, isNot(b.operatorId));
      expect(a.signPublicKey, isNot(b.signPublicKey));
    });

    test('signatures verify only under the right key', () async {
      final alice = await makeIdentity();
      final mallory = await makeIdentity();
      final msg = utf8.encode('launch order');

      final sig = await alice.sign(msg);
      expect(await OperatorIdentity.verify(msg, sig, alice.signPublicKey), isTrue);
      expect(await OperatorIdentity.verify(msg, sig, mallory.signPublicKey), isFalse);
      expect(
        await OperatorIdentity.verify(utf8.encode('stand down'), sig, alice.signPublicKey),
        isFalse,
      );
    });
  });

  group('pairwise encryption', () {
    test('round-trips between the two intended parties', () async {
      final alice = await makeIdentity();
      final bob = await makeIdentity();
      final aliceEngine = E2EEEngine(identity: alice);
      final bobEngine = E2EEEngine(identity: bob);

      final aad = utf8.encode('header');
      final ct = await aliceEngine.encryptPayload('grid ref 42', bob.kexPublicKey, aad: aad);
      final pt = await bobEngine.decryptPayload(ct, alice.kexPublicKey, aad: aad);

      expect(pt, 'grid ref 42');
    });

    test('a third party holding both public keys cannot decrypt', () async {
      // This is the property the old build did not have: its session key was
      // sha256 of the two *public* keys, so anyone who saw them could read
      // everything. Here the private key is required.
      final alice = await makeIdentity();
      final bob = await makeIdentity();
      final eve = await makeIdentity();

      final aad = utf8.encode('header');
      final ct = await E2EEEngine(identity: alice)
          .encryptPayload('grid ref 42', bob.kexPublicKey, aad: aad);

      await expectLater(
        E2EEEngine(identity: eve).decryptPayload(ct, alice.kexPublicKey, aad: aad),
        throwsA(isA<DecryptionFailure>()),
      );
    });

    test('ciphertext is non-deterministic', () async {
      final alice = await makeIdentity();
      final bob = await makeIdentity();
      final engine = E2EEEngine(identity: alice);
      final aad = utf8.encode('header');

      final a = await engine.encryptPayload('same', bob.kexPublicKey, aad: aad);
      final b = await engine.encryptPayload('same', bob.kexPublicKey, aad: aad);
      expect(a, isNot(b));
    });

    test('tampered ciphertext is rejected', () async {
      final alice = await makeIdentity();
      final bob = await makeIdentity();
      final aad = utf8.encode('header');

      final ct = await E2EEEngine(identity: alice)
          .encryptPayload('hold position', bob.kexPublicKey, aad: aad);

      final payload = jsonDecode(utf8.decode(base64Decode(ct))) as Map<String, dynamic>;
      final corrupted = base64Decode(payload['c'] as String);
      corrupted[0] ^= 0xFF;
      payload['c'] = base64Encode(corrupted);
      final tampered = base64Encode(utf8.encode(jsonEncode(payload)));

      await expectLater(
        E2EEEngine(identity: bob).decryptPayload(tampered, alice.kexPublicKey, aad: aad),
        throwsA(isA<DecryptionFailure>()),
      );
    });

    test('a mismatched header breaks decryption', () async {
      final alice = await makeIdentity();
      final bob = await makeIdentity();

      final ct = await E2EEEngine(identity: alice).encryptPayload(
        'for bob only',
        bob.kexPublicKey,
        aad: utf8.encode('to:bob'),
      );

      await expectLater(
        E2EEEngine(identity: bob)
            .decryptPayload(ct, alice.kexPublicKey, aad: utf8.encode('to:carol')),
        throwsA(isA<DecryptionFailure>()),
      );
    });

    test('replayed ciphertext is rejected', () async {
      final alice = await makeIdentity();
      final bob = await makeIdentity();
      final bobEngine = E2EEEngine(identity: bob);
      final aad = utf8.encode('header');

      final ct = await E2EEEngine(identity: alice)
          .encryptPayload('once', bob.kexPublicKey, aad: aad);

      expect(await bobEngine.decryptPayload(ct, alice.kexPublicKey, aad: aad), 'once');
      await expectLater(
        bobEngine.decryptPayload(ct, alice.kexPublicKey, aad: aad),
        throwsA(isA<DecryptionFailure>()),
      );
    });

    test('safety number is symmetric and key-dependent', () async {
      final a = await makeIdentity();
      final b = await makeIdentity();
      final c = await makeIdentity();

      final ab = E2EEEngine.computeSafetyNumber(a.signPublicKey, b.signPublicKey);
      final ba = E2EEEngine.computeSafetyNumber(b.signPublicKey, a.signPublicKey);
      final ac = E2EEEngine.computeSafetyNumber(a.signPublicKey, c.signPublicKey);

      expect(ab, ba);
      expect(ab, isNot(ac));
      // Every digit carries entropy; the old version replaced hex letters with
      // a constant '7', which collapsed most of the fingerprint.
      expect(ab.replaceAll(' ', '').length, 60);
      expect(RegExp(r'^[0-9 ]+$').hasMatch(ab), isTrue);
    });
  });

  group('team key', () {
    TeamGroupEngine engine(String secret) => TeamGroupEngine(
          groupId: 'grp-test',
          groupName: 'TEST',
          groupSecret: secret,
        );

    test('members sharing a secret can read each other', () async {
      final secret = TeamGroupEngine.generateSecret();
      final aad = utf8.encode('header');

      final ct = await engine(secret).encryptGroupMessage('rally point', aad: aad);
      final pt = await engine(secret)
          .decryptGroupMessage(ct, aad: aad, senderId: 'op-someone');

      expect(pt, 'rally point');
    });

    test('a different team secret cannot read the traffic', () async {
      final aad = utf8.encode('header');
      final ct = await engine(TeamGroupEngine.generateSecret())
          .encryptGroupMessage('rally point', aad: aad);

      await expectLater(
        engine(TeamGroupEngine.generateSecret())
            .decryptGroupMessage(ct, aad: aad, senderId: 'op-someone'),
        throwsA(isA<DecryptionFailure>()),
      );
    });

    test('generated secrets are unpredictable', () {
      final secrets = List.generate(64, (_) => TeamGroupEngine.generateSecret());
      expect(secrets.toSet().length, 64);
      expect(base64Decode(secrets.first).length, 32);
    });

    test('one-directional exchange leaves the sides diverged', () async {
      // Regression: PAIR_ACK only carries the approver's secret. Merging picks
      // the lexicographically smaller value, so whenever the requester already
      // holds the smaller one, the approver is left on its own key unless the
      // result is sent back. Half of all pairings landed here, and every piece
      // of team traffic between them failed to decrypt.
      final lower = 'AAAA${TeamGroupEngine.generateSecret().substring(4)}';
      final higher = 'zzzz${TeamGroupEngine.generateSecret().substring(4)}';

      final requester = engine(lower);
      final approver = engine(higher);

      // Only the approver's secret travels (the PAIR_ACK leg).
      await requester.mergeWithPeerSecret(approver.groupSecret, 1);
      expect(requester.groupSecret, lower, reason: 'requester keeps the smaller secret');
      expect(approver.groupSecret, higher);
      expect(requester.groupSecret == approver.groupSecret, isFalse,
          reason: 'without a return leg the two sides diverge');

      // The TEAM_KEY_SYNC return leg closes it in one round.
      await approver.mergeWithPeerSecret(requester.groupSecret, 1);
      expect(approver.groupSecret, requester.groupSecret);
    });

    test('convergence terminates and is idempotent', () async {
      final a = engine('AAAA${TeamGroupEngine.generateSecret().substring(4)}');
      final b = engine('zzzz${TeamGroupEngine.generateSecret().substring(4)}');

      await a.mergeWithPeerSecret(b.groupSecret, 1);
      await b.mergeWithPeerSecret(a.groupSecret, 1);
      final settled = a.groupSecret;

      // Further exchanges must not flip anything back.
      expect(await a.mergeWithPeerSecret(b.groupSecret, 1), isFalse);
      expect(await b.mergeWithPeerSecret(a.groupSecret, 1), isFalse);
      expect(a.groupSecret, settled);
      expect(b.groupSecret, settled);
    });

    test('secret convergence is order independent', () async {
      final s1 = TeamGroupEngine.generateSecret();
      final s2 = TeamGroupEngine.generateSecret();

      final a = engine(s1);
      final b = engine(s2);
      await a.mergeWithPeerSecret(s2, 1);
      await b.mergeWithPeerSecret(s1, 1);

      expect(a.groupSecret, b.groupSecret);
    });
  });

  group('envelope authentication', () {
    test('a valid envelope opens for the intended recipient', () async {
      final alice = await makeIdentity();
      final bob = await makeIdentity();

      final aliceChannel = SecureChannel(
        identity: alice,
        pairwise: E2EEEngine(identity: alice),
        team: TeamGroupEngine(
            groupId: 'g', groupName: 'g', groupSecret: TeamGroupEngine.generateSecret()),
        lookupContact: (_) => profileFor(bob, 'BRAVO'),
      );
      final bobChannel = SecureChannel(
        identity: bob,
        pairwise: E2EEEngine(identity: bob),
        team: TeamGroupEngine(
            groupId: 'g', groupName: 'g', groupSecret: TeamGroupEngine.generateSecret()),
        lookupContact: (_) => profileFor(alice, 'ALPHA'),
      );

      final sealed = await aliceChannel.sealDirect(
        type: MessageType.chat1to1,
        recipient: profileFor(bob, 'BRAVO'),
        plaintext: 'contact front',
      );

      final wire = C2Message.fromEnvelopeJson(sealed.toEnvelopeJson(), bob.operatorId);
      final result = await bobChannel.open(wire);

      expect(result, isA<OpenedMessage>());
      expect((result as OpenedMessage).plaintext, 'contact front');
    });

    test('an envelope claiming another operator ID is rejected', () async {
      // The old build derived the decryption key from the key carried by the
      // message, so anyone could produce readable traffic under any name.
      final alice = await makeIdentity();
      final bob = await makeIdentity();
      final mallory = await makeIdentity();

      final malloryChannel = SecureChannel(
        identity: mallory,
        pairwise: E2EEEngine(identity: mallory),
        team: TeamGroupEngine(
            groupId: 'g', groupName: 'g', groupSecret: TeamGroupEngine.generateSecret()),
        lookupContact: (_) => profileFor(bob, 'BRAVO'),
      );

      final sealed = await malloryChannel.sealDirect(
        type: MessageType.chat1to1,
        recipient: profileFor(bob, 'BRAVO'),
        plaintext: 'fall back to grid 12',
      );

      // Mallory relabels the envelope as coming from Alice.
      final forged = sealed.toEnvelopeJson()..['sender_id'] = alice.operatorId;

      final bobChannel = SecureChannel(
        identity: bob,
        pairwise: E2EEEngine(identity: bob),
        team: TeamGroupEngine(
            groupId: 'g', groupName: 'g', groupSecret: TeamGroupEngine.generateSecret()),
        lookupContact: (_) => profileFor(alice, 'ALPHA'),
      );

      final result = await bobChannel.open(
        C2Message.fromEnvelopeJson(forged, bob.operatorId),
      );

      expect(result, isA<RejectedMessage>());
      expect((result as RejectedMessage).reason, RejectionReason.badSignature);
    });

    test('traffic from an unpaired operator is rejected', () async {
      final bob = await makeIdentity();
      final stranger = await makeIdentity();

      final strangerChannel = SecureChannel(
        identity: stranger,
        pairwise: E2EEEngine(identity: stranger),
        team: TeamGroupEngine(
            groupId: 'g', groupName: 'g', groupSecret: TeamGroupEngine.generateSecret()),
        lookupContact: (_) => profileFor(bob, 'BRAVO'),
      );

      final sealed = await strangerChannel.sealDirect(
        type: MessageType.chat1to1,
        recipient: profileFor(bob, 'BRAVO'),
        plaintext: 'UNPAIR_AND_PURGE',
      );

      final bobChannel = SecureChannel(
        identity: bob,
        pairwise: E2EEEngine(identity: bob),
        team: TeamGroupEngine(
            groupId: 'g', groupName: 'g', groupSecret: TeamGroupEngine.generateSecret()),
        lookupContact: (_) => null, // Nobody is paired.
      );

      final result = await bobChannel.open(
        C2Message.fromEnvelopeJson(sealed.toEnvelopeJson(), bob.operatorId),
      );

      expect(result, isA<RejectedMessage>());
      expect((result as RejectedMessage).reason, RejectionReason.unknownSender);
    });

    test('a modified envelope header invalidates the signature', () async {
      final alice = await makeIdentity();
      final bob = await makeIdentity();

      final aliceChannel = SecureChannel(
        identity: alice,
        pairwise: E2EEEngine(identity: alice),
        team: TeamGroupEngine(
            groupId: 'g', groupName: 'g', groupSecret: TeamGroupEngine.generateSecret()),
        lookupContact: (_) => profileFor(bob, 'BRAVO'),
      );

      final sealed = await aliceChannel.sealDirect(
        type: MessageType.chat1to1,
        recipient: profileFor(bob, 'BRAVO'),
        plaintext: 'hold',
      );

      final tampered = sealed.toEnvelopeJson()..['timestamp'] = 1;

      final bobChannel = SecureChannel(
        identity: bob,
        pairwise: E2EEEngine(identity: bob),
        team: TeamGroupEngine(
            groupId: 'g', groupName: 'g', groupSecret: TeamGroupEngine.generateSecret()),
        lookupContact: (_) => profileFor(alice, 'ALPHA'),
      );

      final result = await bobChannel.open(
        C2Message.fromEnvelopeJson(tampered, bob.operatorId),
      );
      expect(result, isA<RejectedMessage>());
    });
  });

  group('pairing payloads', () {
    test('a payload whose ID does not match its key is refused', () async {
      final alice = await makeIdentity();
      final mallory = await makeIdentity();

      final forged = {
        'operator_id': alice.operatorId, // Claimed
        'callsign': 'ALPHA',
        'name': 'ALPHA',
        'sign_public_key': mallory.signPublicKey, // Actually Mallory's
        'kex_public_key': mallory.kexPublicKey,
      };

      expect(SecureChannel.contactFromPairingPayload(forged), isNull);
    });

    test('a pre-v2 payload without identity keys is refused', () {
      expect(
        SecureChannel.contactFromPairingPayload({
          'operator_id': 'op-legacy',
          'callsign': 'OLD',
          'public_key': 'pubkey_old_style',
        }),
        isNull,
      );
    });

    test('a well-formed payload yields a contact with a derived ID', () async {
      final alice = await makeIdentity();
      final contact = SecureChannel.contactFromPairingPayload({
        'operator_id': alice.operatorId,
        'callsign': 'ALPHA',
        'name': 'ALPHA',
        'sign_public_key': alice.signPublicKey,
        'kex_public_key': alice.kexPublicKey,
      });

      expect(contact, isNotNull);
      expect(contact!.id, alice.operatorId);
      expect(contact.hasValidKeys, isTrue);
    });
  });

  _admissionRuleTests();
  _freshnessTests();

  group('message persistence', () {
    test('decrypted text survives a storage round-trip', () async {
      // Regression: the wire form drops decryptedBody, so restoring history
      // through it made every past message render as "Decryption Failed".
      final msg = C2Message(
        id: 'm1',
        type: MessageType.chat1to1,
        senderId: 'op-abc',
        senderSignKey: 'k',
        recipientId: 'op-def',
        encryptedBody: 'ciphertext',
        decryptedBody: 'readable text',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

      final restored = C2Message.fromEnvelopeJson(msg.toStorageJson(), 'op-def');
      expect(restored.decryptedBody, 'readable text');
      expect(restored.id, 'm1');
    });

    test('an unknown envelope type is rejected, not defaulted', () {
      expect(
        () => C2Message.fromEnvelopeJson({
          'id': 'x',
          'type': 'NOT_A_REAL_TYPE',
          'sender_id': 'op-abc',
          'encrypted_body': '',
        }, 'op-me'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

/// Regression coverage for the P2P admission rule.
///
/// The engine originally refused any link from an operator it had not paired
/// with. That made pairing impossible on an isolated network: a PAIR_REQUEST
/// has nowhere else to travel when no relay is reachable, and at that moment
/// neither device is a contact of the other. The rule is now "provisional links
/// are allowed, but may carry only a pairing request".
void _admissionRuleTests() {
  bool admits(MessageType type, {required bool paired}) =>
      paired || type == MessageType.pairRequest;

  group('p2p link admission', () {
    test('an unpaired operator may deliver a pairing request', () {
      expect(admits(MessageType.pairRequest, paired: false), isTrue);
    });

    test('an unpaired operator may deliver nothing else', () {
      for (final type in [
        MessageType.chat1to1,
        MessageType.chatGroup,
        MessageType.broadcast,
        MessageType.callSignaling,
        MessageType.telemetry,
        MessageType.sosAlert,
        MessageType.waypoint,
      ]) {
        expect(admits(type, paired: false), isFalse, reason: '$type must be refused');
      }
    });

    test('a paired contact may deliver anything', () {
      for (final type in MessageType.values) {
        expect(admits(type, paired: true), isTrue);
      }
    });
  });
}

/// Freshness must be judged against the sender's own reporting cadence.
void _freshnessTests() {
  Telemetry at(Duration ago, {Duration? interval}) => Telemetry(
        operatorId: 'op-abc',
        latitude: 1,
        longitude: 2,
        altitude: 0,
        speed: 0,
        heading: 0,
        accuracy: 5,
        batteryLevel: 90,
        isCharging: false,
        networkType: NetworkType.wifi,
        cellularSignalBars: 0,
        wifiSSID: '',
        timestamp: DateTime.now().subtract(ago),
        reportInterval: interval ?? const Duration(minutes: 15),
      );

  group('telemetry freshness', () {
    test('a device inside its own cadence is not stale', () {
      // Regression: the threshold was a flat one minute while a stationary
      // device only transmits every 15-30, so healthy peers read as stale
      // essentially always and the indicator meant nothing.
      expect(at(const Duration(minutes: 10)).isStale, isFalse);
      expect(at(const Duration(minutes: 30)).isStale, isFalse);
    });

    test('missing roughly two reports is stale', () {
      expect(at(const Duration(minutes: 40)).isStale, isTrue);
      expect(at(const Duration(minutes: 40)).isOffline, isFalse);
    });

    test('prolonged silence is offline', () {
      expect(at(const Duration(minutes: 80)).isOffline, isTrue);
    });

    test('a fast reporter is judged on its faster cadence', () {
      const fast = Duration(seconds: 30);
      expect(at(const Duration(seconds: 20), interval: fast).isStale, isFalse);
      expect(at(const Duration(minutes: 2), interval: fast).isStale, isTrue);
      expect(at(const Duration(minutes: 5), interval: fast).isOffline, isTrue);
    });

    test('the cadence survives a serialisation round trip', () {
      const interval = Duration(minutes: 20);
      final restored = Telemetry.fromJson(at(Duration.zero, interval: interval).toJson());
      expect(restored.reportInterval, interval);
    });

    test('a payload without a cadence falls back to a sane default', () {
      final json = at(Duration.zero).toJson()..remove('report_interval_ms');
      expect(Telemetry.fromJson(json).reportInterval, const Duration(minutes: 15));
    });
  });
}
