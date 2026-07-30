import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/double_ratchet.dart';
import 'package:vector_c2/crypto/e2ee_engine.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/crypto/ratchet_store.dart';
import 'package:vector_c2/models/c2_message.dart';

/// Double Ratchet: forward secrecy and post-compromise recovery on the pairwise
/// path.
///
/// The gap this closes: pairwise keys were static per contact, so a device
/// compromised today decrypted every conversation ever captured from it, and
/// there was no recovery once state leaked.
///
/// The tests that carry the actual security claims are in the "forward secrecy"
/// and "post-compromise recovery" groups — they capture ciphertext, then hand an
/// adversary the *later* state and require that it still cannot read the earlier
/// traffic. Everything else exists so those two cannot pass by accident.
void main() {
  /// A pair of engines wired to each other, as SecureChannel would use them.
  Future<
      ({
        OperatorIdentity alice,
        OperatorIdentity bob,
        E2EEEngine aliceEngine,
        E2EEEngine bobEngine,
        InMemoryRatchetStore aliceStore,
        InMemoryRatchetStore bobStore,
      })> pair() async {
    final alice = await OperatorIdentity.forTesting();
    final bob = await OperatorIdentity.forTesting();
    final aliceStore = InMemoryRatchetStore();
    final bobStore = InMemoryRatchetStore();
    return (
      alice: alice,
      bob: bob,
      aliceEngine: E2EEEngine(identity: alice, store: aliceStore),
      bobEngine: E2EEEngine(identity: bob, store: bobStore),
      aliceStore: aliceStore,
      bobStore: bobStore,
    );
  }

  /// Envelope AAD, so the tests bind the same additional data production does.
  List<int> aadFor(String id, OperatorIdentity from, OperatorIdentity to) =>
      C2Message.aadFor(
        id: id,
        type: MessageType.chat1to1,
        senderId: from.operatorId,
        senderSignKey: from.signPublicKey,
        recipientId: to.operatorId,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  group('basic exchange', () {
    test('either operator can send the first message', () async {
      // The reason roles are assigned by key order rather than by who initiates:
      // a textbook responder has no sending chain until it has received
      // something, which would mean one of the two operators could not start a
      // conversation. Both directions are checked here.
      for (final aliceFirst in [true, false]) {
        final p = await pair();
        final aad = aadFor('m1', aliceFirst ? p.alice : p.bob,
            aliceFirst ? p.bob : p.alice);

        final sender = aliceFirst ? p.aliceEngine : p.bobEngine;
        final receiver = aliceFirst ? p.bobEngine : p.aliceEngine;
        final senderPeerKey =
            aliceFirst ? p.bob.kexPublicKey : p.alice.kexPublicKey;
        final receiverPeerKey =
            aliceFirst ? p.alice.kexPublicKey : p.bob.kexPublicKey;

        final sealed = await sender.encryptPayload('first', senderPeerKey, aad: aad);
        expect(
          await receiver.decryptPayload(sealed, receiverPeerKey, aad: aad),
          'first',
          reason: aliceFirst
              ? 'the initiator must be able to open the conversation'
              : 'the responder must be able to open the conversation too',
        );
      }
    });

    test('a full back-and-forth conversation stays in step', () async {
      final p = await pair();

      for (var round = 0; round < 6; round++) {
        final toBobAad = aadFor('a$round', p.alice, p.bob);
        final sealedToBob =
            await p.aliceEngine.encryptPayload('alice $round', p.bob.kexPublicKey, aad: toBobAad);
        expect(
          await p.bobEngine.decryptPayload(sealedToBob, p.alice.kexPublicKey, aad: toBobAad),
          'alice $round',
        );

        final toAliceAad = aadFor('b$round', p.bob, p.alice);
        final sealedToAlice =
            await p.bobEngine.encryptPayload('bob $round', p.alice.kexPublicKey, aad: toAliceAad);
        expect(
          await p.aliceEngine.decryptPayload(sealedToAlice, p.bob.kexPublicKey, aad: toAliceAad),
          'bob $round',
        );
      }
    });

    test('many consecutive messages one way advance the symmetric chain', () async {
      // No DH ratchet happens without return traffic, so this exercises the
      // symmetric chain on its own.
      final p = await pair();
      for (var i = 0; i < 40; i++) {
        final aad = aadFor('m$i', p.alice, p.bob);
        final sealed =
            await p.aliceEngine.encryptPayload('msg $i', p.bob.kexPublicKey, aad: aad);
        expect(
          await p.bobEngine.decryptPayload(sealed, p.alice.kexPublicKey, aad: aad),
          'msg $i',
        );
      }
    });

    test('every message produces a distinct ciphertext and header', () async {
      final p = await pair();
      final headers = <String>{};
      final bodies = <String>{};

      for (var i = 0; i < 12; i++) {
        final aad = aadFor('m$i', p.alice, p.bob);
        final sealed =
            await p.aliceEngine.encryptPayload('identical', p.bob.kexPublicKey, aad: aad);
        final payload =
            jsonDecode(utf8.decode(base64Decode(sealed))) as Map<String, dynamic>;
        expect(payload['v'], 3, reason: 'v3 is the ratcheted format');
        headers.add(jsonEncode(payload['h']));
        bodies.add(payload['c'] as String);
      }

      expect(headers, hasLength(12));
      expect(bodies, hasLength(12),
          reason: 'the same plaintext must never seal to the same ciphertext');
    });
  });

  group('forward secrecy', () {
    test('later session state cannot decrypt earlier ciphertext', () async {
      // The core claim. Capture traffic, let the conversation move on, then give
      // an adversary Bob's *current* state — the situation after seizing his
      // device — and require that the captured messages stay closed.
      final p = await pair();

      final earlyAad = aadFor('early', p.alice, p.bob);
      final capturedEarly =
          await p.aliceEngine.encryptPayload('the early secret', p.bob.kexPublicKey, aad: earlyAad);

      // Bob reads it legitimately, consuming the key.
      expect(
        await p.bobEngine.decryptPayload(capturedEarly, p.alice.kexPublicKey, aad: earlyAad),
        'the early secret',
      );

      // The conversation continues, ratcheting several times.
      for (var i = 0; i < 4; i++) {
        final ab = aadFor('a$i', p.alice, p.bob);
        await p.bobEngine.decryptPayload(
          await p.aliceEngine.encryptPayload('a$i', p.bob.kexPublicKey, aad: ab),
          p.alice.kexPublicKey,
          aad: ab,
        );
        final ba = aadFor('b$i', p.bob, p.alice);
        await p.aliceEngine.decryptPayload(
          await p.bobEngine.encryptPayload('b$i', p.alice.kexPublicKey, aad: ba),
          p.bob.kexPublicKey,
          aad: ba,
        );
      }

      // Seize Bob's device: everything persisted, plus his long-term keys.
      final seizedState = await p.bobStore.read(p.alice.kexPublicKey);
      expect(seizedState, isNotNull);

      final adversary = E2EEEngine(identity: p.bob, store: InMemoryRatchetStore());
      await adversary.store.write(p.alice.kexPublicKey, seizedState!);

      await expectLater(
        adversary.decryptPayload(capturedEarly, p.alice.kexPublicKey, aad: earlyAad),
        throwsA(isA<DecryptionFailure>()),
        reason: 'this is the whole point of the ratchet — without forward '
            'secrecy the static key would open this immediately',
      );
    });

    test('a used message key is gone, so a replay fails', () async {
      final p = await pair();
      final aad = aadFor('once', p.alice, p.bob);
      final sealed =
          await p.aliceEngine.encryptPayload('once only', p.bob.kexPublicKey, aad: aad);

      expect(
        await p.bobEngine.decryptPayload(sealed, p.alice.kexPublicKey, aad: aad),
        'once only',
      );
      await expectLater(
        p.bobEngine.decryptPayload(sealed, p.alice.kexPublicKey, aad: aad),
        throwsA(isA<DecryptionFailure>()),
        reason: 'the key was deleted on use; no nonce list is needed to notice',
      );
    });

    test('after a round trip the long-term keys alone no longer open traffic', () async {
      // Under v2 the session key was a pure function of the two static keys, so
      // holding them was equivalent to holding every message key, forever. Once
      // a DH step has happened the chain depends on ephemeral private keys that
      // exist only in live session state.
      final p = await pair();

      // One full round trip, which is what performs the first DH ratchet.
      final warm = aadFor('warm', p.alice, p.bob);
      await p.bobEngine.decryptPayload(
        await p.aliceEngine.encryptPayload('warm', p.bob.kexPublicKey, aad: warm),
        p.alice.kexPublicKey,
        aad: warm,
      );
      final back = aadFor('back', p.bob, p.alice);
      await p.aliceEngine.decryptPayload(
        await p.bobEngine.encryptPayload('back', p.alice.kexPublicKey, aad: back),
        p.bob.kexPublicKey,
        aad: back,
      );

      final aad = aadFor('m', p.alice, p.bob);
      final sealed =
          await p.aliceEngine.encryptPayload('secret', p.bob.kexPublicKey, aad: aad);

      final freshBob = E2EEEngine(identity: p.bob, store: InMemoryRatchetStore());
      await expectLater(
        freshBob.decryptPayload(sealed, p.alice.kexPublicKey, aad: aad),
        throwsA(isA<DecryptionFailure>()),
        reason: 'holding the long-term agreement key must not be enough once '
            'the ratchet has turned',
      );
    });

    test('KNOWN LIMIT: the first chain of a direction is derivable from the '
        'long-term keys until the first round trip', () async {
      // Asserted rather than left implicit, so it cannot change silently and so
      // the claim in SECURITY.md stays honest.
      //
      // The bootstrap has no prekeys — there is no server to publish them to and
      // no extra round trip to spend — so a direction's opening chain is a
      // function of the two static keys plus the sender's ratchet public key,
      // which travels in the header. Seizing a device therefore still exposes
      // captured traffic sent before that conversation's first reply. After one
      // reply, the test above applies instead.
      final p = await pair();
      final aad = aadFor('opening', p.alice, p.bob);
      final sealed = await p.aliceEngine
          .encryptPayload('opening message', p.bob.kexPublicKey, aad: aad);

      final freshBob = E2EEEngine(identity: p.bob, store: InMemoryRatchetStore());
      expect(
        await freshBob.decryptPayload(sealed, p.alice.kexPublicKey, aad: aad),
        'opening message',
        reason: 'if this ever starts throwing, the bootstrap gained forward '
            'secrecy and SECURITY.md should be updated to say so',
      );
    });
  });

  group('post-compromise recovery', () {
    test('state stolen now stops working after a round trip it misses', () async {
      final p = await pair();

      // Adversary copies Bob's state at this moment.
      final aad0 = aadFor('m0', p.alice, p.bob);
      await p.bobEngine.decryptPayload(
        await p.aliceEngine.encryptPayload('m0', p.bob.kexPublicKey, aad: aad0),
        p.alice.kexPublicKey,
        aad: aad0,
      );
      final stolen = await p.bobStore.read(p.alice.kexPublicKey);
      final adversary = E2EEEngine(identity: p.bob, store: InMemoryRatchetStore());
      await adversary.store.write(p.alice.kexPublicKey, stolen!);

      // Recovery costs two round trips, and it is worth being precise about why.
      // The stolen state contains the ratchet keypair Bob is using right now, so
      // it can follow the very next DH step. Bob generates a *new* keypair only
      // while receiving, and only chains rooted in that new key are closed to the
      // adversary:
      //
      //   1. Bob replies   -> Alice ratchets, generating a new key of her own
      //   2. Alice sends   -> Bob ratchets, generating the key the adversary has
      //                       never held. This message is still readable to it.
      //   3. Bob replies   -> Alice ratchets again
      //   4. Alice sends   -> rooted in Bob's post-theft key: locked out
      Future<void> bobToAlice(String id) async {
        final aad = aadFor(id, p.bob, p.alice);
        await p.aliceEngine.decryptPayload(
          await p.bobEngine.encryptPayload(id, p.alice.kexPublicKey, aad: aad),
          p.bob.kexPublicKey,
          aad: aad,
        );
      }

      Future<String> aliceToBob(String id) async {
        final aad = aadFor(id, p.alice, p.bob);
        final sealed =
            await p.aliceEngine.encryptPayload(id, p.bob.kexPublicKey, aad: aad);
        expect(
          await p.bobEngine.decryptPayload(sealed, p.alice.kexPublicKey, aad: aad),
          id,
        );
        return sealed;
      }

      await bobToAlice('reply1');
      await aliceToBob('mid');
      await bobToAlice('reply2');

      final finalAad = aadFor('final', p.alice, p.bob);
      final sealedFinal =
          await p.aliceEngine.encryptPayload('after recovery', p.bob.kexPublicKey, aad: finalAad);

      expect(
        await p.bobEngine.decryptPayload(sealedFinal, p.alice.kexPublicKey, aad: finalAad),
        'after recovery',
        reason: 'the legitimate peer must still be able to read it',
      );

      await expectLater(
        adversary.decryptPayload(sealedFinal, p.alice.kexPublicKey, aad: finalAad),
        throwsA(isA<DecryptionFailure>()),
        reason: 'a DH step with a key generated after the theft locks the '
            'adversary out',
      );
    });
  });

  group('out-of-order and missing messages', () {
    test('messages that arrive reversed both open', () async {
      // Call signalling delivers ICE candidates in bursts that genuinely arrive
      // out of order, so this is a normal case, not an edge case.
      final p = await pair();
      final aad1 = aadFor('m1', p.alice, p.bob);
      final aad2 = aadFor('m2', p.alice, p.bob);

      final first = await p.aliceEngine.encryptPayload('first', p.bob.kexPublicKey, aad: aad1);
      final second = await p.aliceEngine.encryptPayload('second', p.bob.kexPublicKey, aad: aad2);

      expect(await p.bobEngine.decryptPayload(second, p.alice.kexPublicKey, aad: aad2), 'second');
      expect(await p.bobEngine.decryptPayload(first, p.alice.kexPublicKey, aad: aad1), 'first');
    });

    test('a message lost forever does not block the ones after it', () async {
      final p = await pair();
      final aads = [for (var i = 0; i < 5; i++) aadFor('m$i', p.alice, p.bob)];
      final sealed = <String>[];
      for (var i = 0; i < 5; i++) {
        sealed.add(
            await p.aliceEngine.encryptPayload('m$i', p.bob.kexPublicKey, aad: aads[i]));
      }

      // Drop index 1 and 3 entirely.
      for (final i in [0, 2, 4]) {
        expect(
          await p.bobEngine.decryptPayload(sealed[i], p.alice.kexPublicKey, aad: aads[i]),
          'm$i',
        );
      }
    });

    test('a message from a superseded chain still opens after a ratchet', () async {
      // Alice sends two, Bob only receives the second, replies (forcing a DH
      // ratchet on Alice), and the straggler from the old chain arrives late.
      final p = await pair();
      final aadA = aadFor('a', p.alice, p.bob);
      final aadB = aadFor('b', p.alice, p.bob);

      final straggler = await p.aliceEngine.encryptPayload('straggler', p.bob.kexPublicKey, aad: aadA);
      final arrived = await p.aliceEngine.encryptPayload('arrived', p.bob.kexPublicKey, aad: aadB);

      expect(await p.bobEngine.decryptPayload(arrived, p.alice.kexPublicKey, aad: aadB), 'arrived');

      final reply = aadFor('r', p.bob, p.alice);
      await p.aliceEngine.decryptPayload(
        await p.bobEngine.encryptPayload('reply', p.alice.kexPublicKey, aad: reply),
        p.bob.kexPublicKey,
        aad: reply,
      );

      final next = aadFor('n', p.alice, p.bob);
      await p.bobEngine.decryptPayload(
        await p.aliceEngine.encryptPayload('next chain', p.bob.kexPublicKey, aad: next),
        p.alice.kexPublicKey,
        aad: next,
      );

      expect(
        await p.bobEngine.decryptPayload(straggler, p.alice.kexPublicKey, aad: aadA),
        'straggler',
        reason: 'the retained key from the previous chain must survive the '
            'ratchet, or every reordered message across a turn is lost',
      );
    });

    test('an absurd chain gap is refused rather than derived', () async {
      final p = await pair();
      final aad = aadFor('m', p.alice, p.bob);
      final sealed = await p.aliceEngine.encryptPayload('m', p.bob.kexPublicKey, aad: aad);

      // Rewrite n to something enormous. Without the skip cap this would make
      // the receiver derive that many keys.
      final payload = jsonDecode(utf8.decode(base64Decode(sealed))) as Map<String, dynamic>;
      (payload['h'] as Map<String, dynamic>)['n'] = 100000;
      final tampered = base64Encode(utf8.encode(jsonEncode(payload)));

      await expectLater(
        p.bobEngine.decryptPayload(tampered, p.alice.kexPublicKey, aad: aad),
        throwsA(isA<DecryptionFailure>()),
      );
    });
  });

  group('tampering', () {
    test('a forged message does not desynchronise the session', () async {
      // A failed decryption must roll the session back. If a forgery could
      // advance the chain, anyone able to inject one packet could permanently
      // break a conversation.
      final p = await pair();
      final aad = aadFor('m', p.alice, p.bob);
      final sealed = await p.aliceEngine.encryptPayload('genuine', p.bob.kexPublicKey, aad: aad);

      final payload = jsonDecode(utf8.decode(base64Decode(sealed))) as Map<String, dynamic>;
      final flipped = base64Decode(payload['c'] as String);
      flipped[0] ^= 0xff;
      final forged = base64Encode(utf8.encode(jsonEncode({
        ...payload,
        'c': base64Encode(flipped),
      })));

      await expectLater(
        p.bobEngine.decryptPayload(forged, p.alice.kexPublicKey, aad: aad),
        throwsA(isA<DecryptionFailure>()),
      );

      // The genuine message must still open.
      expect(
        await p.bobEngine.decryptPayload(sealed, p.alice.kexPublicKey, aad: aad),
        'genuine',
        reason: 'an injected forgery must not cost the conversation its state',
      );
    });

    test('the ratchet header is authenticated', () async {
      final p = await pair();
      final aad = aadFor('m', p.alice, p.bob);
      // Two messages so index 1 exists and rewriting n to 0 is a real swap
      // rather than an out-of-range value.
      await p.aliceEngine.encryptPayload('zero', p.bob.kexPublicKey, aad: aad);
      final sealed = await p.aliceEngine.encryptPayload('one', p.bob.kexPublicKey, aad: aad);

      final payload = jsonDecode(utf8.decode(base64Decode(sealed))) as Map<String, dynamic>;
      (payload['h'] as Map<String, dynamic>)['n'] = 0;
      final tampered = base64Encode(utf8.encode(jsonEncode(payload)));

      await expectLater(
        p.bobEngine.decryptPayload(tampered, p.alice.kexPublicKey, aad: aad),
        throwsA(isA<DecryptionFailure>()),
        reason: 'the header is bound into the AEAD, so editing it breaks the tag',
      );
    });

    test('the envelope header is still bound in', () async {
      // The v2 guarantee must not have been lost in the rewrite: a relay cannot
      // move a ciphertext into a different conversation.
      final p = await pair();
      final realAad = aadFor('m', p.alice, p.bob);
      final sealed = await p.aliceEngine.encryptPayload('m', p.bob.kexPublicKey, aad: realAad);

      await expectLater(
        p.bobEngine.decryptPayload(sealed, p.alice.kexPublicKey,
            aad: aadFor('different-id', p.alice, p.bob)),
        throwsA(isA<DecryptionFailure>()),
      );
    });

    test('a malformed or unknown version is refused', () async {
      final p = await pair();
      final aad = aadFor('m', p.alice, p.bob);

      for (final body in [
        'not base64 at all!!',
        base64Encode(utf8.encode('{}')),
        base64Encode(utf8.encode(jsonEncode({'v': 99}))),
        base64Encode(utf8.encode(jsonEncode({'v': 3, 'h': {'dh': '', 'pn': 0, 'n': 0}}))),
        base64Encode(utf8.encode(jsonEncode({'v': 3, 'h': {'dh': 'AAA', 'pn': -1, 'n': 0}}))),
      ]) {
        await expectLater(
          p.bobEngine.decryptPayload(body, p.alice.kexPublicKey, aad: aad),
          throwsA(isA<DecryptionFailure>()),
          reason: 'rejected input: $body',
        );
      }
    });
  });

  group('persistence', () {
    test('a session resumes across a restart', () async {
      final p = await pair();

      final aad1 = aadFor('m1', p.alice, p.bob);
      await p.bobEngine.decryptPayload(
        await p.aliceEngine.encryptPayload('before restart', p.bob.kexPublicKey, aad: aad1),
        p.alice.kexPublicKey,
        aad: aad1,
      );

      // New engines over the same stores: the app relaunched.
      final aliceAgain = E2EEEngine(identity: p.alice, store: p.aliceStore);
      final bobAgain = E2EEEngine(identity: p.bob, store: p.bobStore);

      final aad2 = aadFor('m2', p.alice, p.bob);
      expect(
        await bobAgain.decryptPayload(
          await aliceAgain.encryptPayload('after restart', p.bob.kexPublicKey, aad: aad2),
          p.alice.kexPublicKey,
          aad: aad2,
        ),
        'after restart',
      );
    });

    test('corrupt stored state re-establishes instead of wedging', () async {
      // Both sides can rebuild deterministically from their static keys, so
      // unreadable state should cost at most the messages in flight — not the
      // conversation.
      final p = await pair();
      await p.aliceStore.write(p.bob.kexPublicKey, 'not json');
      await p.bobStore.write(p.alice.kexPublicKey, '{"v":1}');

      final aad = aadFor('m', p.alice, p.bob);
      expect(
        await p.bobEngine.decryptPayload(
          await p.aliceEngine.encryptPayload('recovered', p.bob.kexPublicKey, aad: aad),
          p.alice.kexPublicKey,
          aad: aad,
        ),
        'recovered',
      );
    });

    test('forgetting a peer clears persisted state', () async {
      final p = await pair();
      final aad = aadFor('m', p.alice, p.bob);
      await p.aliceEngine.encryptPayload('m', p.bob.kexPublicKey, aad: aad);
      expect(p.aliceStore.sessionCount, 1);

      await p.aliceEngine.forgetPeer(p.bob.kexPublicKey);
      expect(p.aliceStore.sessionCount, 0,
          reason: 'leaving state behind would let a re-pair resume a session '
              'the other side has forgotten');
    });

    test('destroyAllSessions wipes every conversation', () async {
      final p = await pair();
      final carol = await OperatorIdentity.forTesting();
      await p.aliceEngine.encryptPayload('x', p.bob.kexPublicKey,
          aad: aadFor('m', p.alice, p.bob));
      await p.aliceEngine.encryptPayload('y', carol.kexPublicKey,
          aad: aadFor('m2', p.alice, carol));
      expect(p.aliceStore.sessionCount, 2);

      await p.aliceEngine.destroyAllSessions();
      expect(p.aliceStore.sessionCount, 0);
    });
  });

  group('concurrency', () {
    test('messages sealed concurrently get distinct keys', () async {
      // PTT and call signalling both seal without awaiting the previous send.
      // Two concurrent encrypts that interleaved a read-modify-write on the
      // chain would derive the same message key twice.
      final p = await pair();
      final aads = [for (var i = 0; i < 10; i++) aadFor('m$i', p.alice, p.bob)];

      final sealed = await Future.wait([
        for (var i = 0; i < 10; i++)
          p.aliceEngine.encryptPayload('m$i', p.bob.kexPublicKey, aad: aads[i]),
      ]);

      final indices = <int>{};
      for (final body in sealed) {
        final payload = jsonDecode(utf8.decode(base64Decode(body))) as Map<String, dynamic>;
        indices.add((payload['h'] as Map<String, dynamic>)['n'] as int);
      }
      expect(indices, hasLength(10),
          reason: 'each concurrent send must occupy its own chain position');

      // And all of them still open.
      for (var i = 0; i < 10; i++) {
        expect(
          await p.bobEngine.decryptPayload(sealed[i], p.alice.kexPublicKey, aad: aads[i]),
          'm$i',
        );
      }
    });
  });

  group('interoperating with an un-updated peer', () {
    test('a v2 ciphertext is still accepted and reported', () async {
      // A squad cannot be expected to update every device at the same moment.
      final p = await pair();
      final aad = aadFor('legacy', p.alice, p.bob);

      // Produce a genuine v2 body the way the previous build did.
      final legacyBody = await _sealLegacyV2(
        identity: p.alice,
        remoteKexPublicKey: p.bob.kexPublicKey,
        plaintext: 'from an old build',
        aad: aad,
      );

      final reported = <String>[];
      p.bobEngine.onLegacyCiphertext = reported.add;

      expect(
        await p.bobEngine.decryptPayload(legacyBody, p.alice.kexPublicKey, aad: aad),
        'from an old build',
      );
      expect(reported, [p.alice.kexPublicKey],
          reason: 'v2 has no forward secrecy; its use should be visible');
    });

    test('nothing is ever sent as v2', () async {
      final p = await pair();
      final sealed = await p.aliceEngine.encryptPayload(
          'x', p.bob.kexPublicKey, aad: aadFor('m', p.alice, p.bob));
      final payload = jsonDecode(utf8.decode(base64Decode(sealed))) as Map<String, dynamic>;
      expect(payload['v'], 3);
    });
  });

  group('session establishment', () {
    test('roles are opposite and derived without communication', () async {
      final alice = await OperatorIdentity.forTesting();
      final bob = await OperatorIdentity.forTesting();

      final aliceSession = await DoubleRatchetSession.establish(
        selfAgreementKeyPair: alice.agreementKeyPair,
        selfKexPublicKey: alice.kexPublicKey,
        remoteKexPublicKey: bob.kexPublicKey,
      );
      final bobSession = await DoubleRatchetSession.establish(
        selfAgreementKeyPair: bob.agreementKeyPair,
        selfKexPublicKey: bob.kexPublicKey,
        remoteKexPublicKey: alice.kexPublicKey,
      );

      expect(aliceSession.isInitiator, isNot(bobSession.isInitiator),
          reason: 'exactly one side must be the initiator, or the bootstrap '
              'chains do not line up');
      expect(
        aliceSession.isInitiator,
        alice.kexPublicKey.compareTo(bob.kexPublicKey) < 0,
        reason: 'the lower agreement key initiates',
      );
    });

    test('a session with self is refused', () async {
      final alice = await OperatorIdentity.forTesting();
      await expectLater(
        DoubleRatchetSession.establish(
          selfAgreementKeyPair: alice.agreementKeyPair,
          selfKexPublicKey: alice.kexPublicKey,
          remoteKexPublicKey: alice.kexPublicKey,
        ),
        throwsA(isA<RatchetFailure>()),
      );
    });

    test('a malformed peer key is refused', () async {
      final alice = await OperatorIdentity.forTesting();
      for (final bad in ['', 'not-base64!!', base64Encode([1, 2, 3])]) {
        await expectLater(
          DoubleRatchetSession.establish(
            selfAgreementKeyPair: alice.agreementKeyPair,
            selfKexPublicKey: alice.kexPublicKey,
            remoteKexPublicKey: bad,
          ),
          throwsA(isA<Object>()),
          reason: 'rejected key: "$bad"',
        );
      }
    });
  });

  group('re-pairing repairs a desynchronised session', () {
    // Observed in the field: both operators reported every pairwise message as
    // "message key already used", in both directions, after their identities had
    // been reprovisioned. Transport, routing, addressing and the team key were
    // all verified correct — the pairwise chains had simply diverged, and the
    // obvious repair of pairing again did nothing, because pairing inherited the
    // old chain position instead of starting a new one.
    test('a one-sided reset does not repair it, and must not appear to', () async {
      final p = await pair();

      final a1 = aadFor('m1', p.alice, p.bob);
      final c1 = await p.aliceEngine.encryptPayload('one', p.bob.kexPublicKey, aad: a1);
      await p.bobEngine.decryptPayload(c1, p.alice.kexPublicKey, aad: a1);

      // Only Alice forgets — the case where one operator deletes the contact and
      // the other re-adds it over the top, which is what happened in the field.
      await p.aliceEngine.forgetPeer(p.bob.kexPublicKey);

      final a2 = aadFor('m2', p.alice, p.bob);
      final c2 = await p.aliceEngine.encryptPayload('two', p.bob.kexPublicKey, aad: a2);

      // Refusal is the correct outcome here. The point being pinned is that a
      // one-sided reset is not a repair, so pairing must reset both ends.
      await expectLater(
        p.bobEngine.decryptPayload(c2, p.alice.kexPublicKey, aad: a2),
        throwsA(isA<DecryptionFailure>()),
      );
    });

    test('a mutual reset repairs it, in both directions', () async {
      final p = await pair();

      final a1 = aadFor('m1', p.alice, p.bob);
      final c1 = await p.aliceEngine.encryptPayload('one', p.bob.kexPublicKey, aad: a1);
      await p.bobEngine.decryptPayload(c1, p.alice.kexPublicKey, aad: a1);

      final b1 = aadFor('m2', p.bob, p.alice);
      final d1 = await p.bobEngine.encryptPayload('two', p.alice.kexPublicKey, aad: b1);
      await p.aliceEngine.decryptPayload(d1, p.bob.kexPublicKey, aad: b1);

      // What pairing now does at both ends: the requester drops its side when it
      // sends PAIR_REQUEST, the approver when it approves.
      await p.aliceEngine.forgetPeer(p.bob.kexPublicKey);
      await p.bobEngine.forgetPeer(p.alice.kexPublicKey);

      final a3 = aadFor('m3', p.alice, p.bob);
      final c3 = await p.aliceEngine.encryptPayload('after', p.bob.kexPublicKey, aad: a3);
      expect(await p.bobEngine.decryptPayload(c3, p.alice.kexPublicKey, aad: a3), 'after');

      final b3 = aadFor('m4', p.bob, p.alice);
      final d3 = await p.bobEngine.encryptPayload('back', p.alice.kexPublicKey, aad: b3);
      expect(await p.aliceEngine.decryptPayload(d3, p.bob.kexPublicKey, aad: b3), 'back');
    });

    test('a reset returns both sides to the bootstrap chain, and no further', () async {
      // This is the documented forward-secrecy gap, pinned rather than wished
      // away. Resetting re-derives the first chain from the two static
      // identities, so traffic captured from *that* chain becomes readable
      // again — SECURITY.md states this under "Forward secrecy has a gap at the
      // start of each conversation", and it is the reason X3DH's one-time
      // prekeys would be needed to close it.
      //
      // What must NOT come back is anything from a later chain, because those
      // keys depend on a ratchet step whose private half the reset discarded.
      final p = await pair();

      final a1 = aadFor('m1', p.alice, p.bob);
      final bootstrap =
          await p.aliceEngine.encryptPayload('first', p.bob.kexPublicKey, aad: a1);
      await p.bobEngine.decryptPayload(bootstrap, p.alice.kexPublicKey, aad: a1);

      // Bob replies, which advances the root key on Alice's side via a DH step.
      final b1 = aadFor('m2', p.bob, p.alice);
      final reply = await p.bobEngine.encryptPayload('reply', p.alice.kexPublicKey, aad: b1);
      await p.aliceEngine.decryptPayload(reply, p.bob.kexPublicKey, aad: b1);

      final a2 = aadFor('m3', p.alice, p.bob);
      final laterChain =
          await p.aliceEngine.encryptPayload('later', p.bob.kexPublicKey, aad: a2);
      await p.bobEngine.decryptPayload(laterChain, p.alice.kexPublicKey, aad: a2);

      await p.aliceEngine.forgetPeer(p.bob.kexPublicKey);
      await p.bobEngine.forgetPeer(p.alice.kexPublicKey);

      // The bootstrap chain is reachable again. Stated, not hidden.
      expect(
        await p.bobEngine.decryptPayload(bootstrap, p.alice.kexPublicKey, aad: a1),
        'first',
        reason: 'the documented bootstrap gap: no prekeys, so the first chain is '
            'a pure function of the two long-term keys',
      );

      // Everything after the first reply stays shut.
      await expectLater(
        p.bobEngine.decryptPayload(laterChain, p.alice.kexPublicKey, aad: a2),
        throwsA(isA<DecryptionFailure>()),
        reason: 'a reset must not recover a chain that depended on a ratchet step',
      );
    });
  });

}

/// Reproduces the pre-ratchet v2 sealing format, so the compatibility path is
/// tested against a real legacy ciphertext rather than a hand-written blob.
Future<String> _sealLegacyV2({
  required OperatorIdentity identity,
  required String remoteKexPublicKey,
  required String plaintext,
  required List<int> aad,
}) async {
  final key = await identity.deriveSharedKey(remoteKexPublicKey,
      info: 'vector-c2/pairwise/v2');
  final aead = AesGcm.with256bits();
  final box = await aead.encrypt(
    utf8.encode(plaintext),
    secretKey: key,
    nonce: aead.newNonce(),
    aad: aad,
  );
  return base64Encode(utf8.encode(jsonEncode({
    'v': 2,
    'n': base64Encode(box.nonce),
    'c': base64Encode(box.cipherText),
    'm': base64Encode(box.mac.bytes),
  })));
}
