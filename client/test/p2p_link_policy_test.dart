import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/services/p2p_mesh_engine.dart';
import 'package:vector_c2/services/transport_policy.dart';

/// Device-to-device links: plaintext, and governed separately from the relay.
///
/// This pins a decision rather than a fix. `TRANSPORT_POLICY` looked like it
/// should cover every socket the app opens, so a build with `tls-only` reading
/// "even a LAN node must present a certificate" was reasonably taken to mean
/// the peer links were encrypted too. They were not, and could not be: there is
/// no certificate infrastructure between two handsets, so refusing plaintext
/// there deletes the mesh instead of upgrading it.
///
/// So the two are independent knobs, and this file is what makes that visible
/// if either one is later changed to imply the other.
void main() {
  // Real sockets: the binding installs HttpOverrides that would otherwise
  // intercept WebSocket.connect, and the whole point here is what goes on the
  // wire.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('P2P_PLAINTEXT parsing', () {
    test('allow and deny map to the two policies', () {
      expect(parseP2PLinkPolicy('allow'), P2PLinkPolicy.plaintextAllowed);
      expect(parseP2PLinkPolicy('ALLOW'), P2PLinkPolicy.plaintextAllowed);
      expect(parseP2PLinkPolicy(' deny '), P2PLinkPolicy.plaintextDenied);
      expect(parseP2PLinkPolicy('disable'), P2PLinkPolicy.plaintextDenied);
    });

    test('an undefined build define means the mesh stays up', () {
      // `--dart-define` absent is the overwhelmingly common case; it must not
      // read as "not understood".
      expect(parseP2PLinkPolicy(''), P2PLinkPolicy.plaintextAllowed);
    });

    test('an unrecognised value is reported rather than guessed', () {
      // Null so the caller can log it. The fallback is applied by the caller
      // and is the permissive end on purpose: the strict end here is "no P2P
      // at all", which a typo in a deploy script should not be able to cause.
      expect(parseP2PLinkPolicy('tls-only'), isNull);
      expect(parseP2PLinkPolicy('true'), isNull);
    });

    test('the engine defaults to allowing plaintext links', () async {
      final engine = P2PMeshEngine(
        identity: await OperatorIdentity.forTesting(),
        isPairedContact: (_) => false,
      );
      expect(engine.linkPolicy, P2PLinkPolicy.plaintextAllowed);
      await engine.dispose();
    });
  });

  group('the relay policy does not reach the P2P path', () {
    late P2PMeshEngine listener;
    late P2PMeshEngine dialer;

    setUp(() async {
      listener = P2PMeshEngine(
        identity: await OperatorIdentity.forTesting(),
        p2pPort: 19190,
        isPairedContact: (_) => false,
        announceEnabled: false, // Dial explicitly; no subnet broadcasts.
      );
      dialer = P2PMeshEngine(
        identity: await OperatorIdentity.forTesting(),
        p2pPort: 19191,
        isPairedContact: (_) => false,
        announceEnabled: false,
      );
      await listener.start();
      await dialer.start();
    });

    tearDown(() async {
      await dialer.dispose();
      await listener.dispose();
    });

    test('a plaintext peer link still forms under a tls-only relay build', () async {
      // The same URL, judged by the relay policy, is refused — stated here so
      // the divergence is deliberate and visible rather than an oversight.
      expect(
        isTransportAllowed('ws://127.0.0.1:19190/ws', TransportPolicy.tlsOnly),
        isFalse,
      );

      // P2PMeshEngine takes no TransportPolicy at all, so a tls-only build
      // changes nothing here. If someone wires one in, this goes red.
      final linked = await dialer.connectToPeer(address: '127.0.0.1', port: 19190);
      expect(linked, isTrue,
          reason: 'peer links are governed by P2P_PLAINTEXT, not TRANSPORT_POLICY');
      expect(dialer.activePeers, hasLength(1));
    });
  });

  group('P2P_PLAINTEXT=deny', () {
    late P2PMeshEngine denied;
    final refusals = <String>[];
    StreamSubscription<String>? sub;

    setUp(() async {
      refusals.clear();
      denied = P2PMeshEngine(
        identity: await OperatorIdentity.forTesting(),
        p2pPort: 19192,
        isPairedContact: (_) => false,
        announceEnabled: false,
        linkPolicy: P2PLinkPolicy.plaintextDenied,
      );
      sub = denied.linkRefusals.listen(refusals.add);
    });

    tearDown(() async {
      await sub?.cancel();
      await denied.dispose();
    });

    test('no listener is bound, so no inbound link can be dialled either', () async {
      await denied.start();

      // Refusing to dial while still accepting would deny nothing: the same
      // plaintext link exists, opened from the other end.
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:19192/ws'),
        throwsA(isA<SocketException>()),
      );
    });

    test('starting the engine says so rather than going quiet', () async {
      await denied.start();
      await Future<void>.delayed(Duration.zero);

      // A disabled mesh and an empty subnet look identical from the outside,
      // which is exactly how a misconfigured build passes for a quiet one.
      expect(refusals, hasLength(1));
      expect(refusals.single, contains('P2P_PLAINTEXT=deny'));
    });

    test('a manual dial is refused before any socket is opened', () async {
      // A peer that is genuinely there and answering: the defect being guarded
      // against is dialling it anyway, so it has to be reachable for the test
      // to mean anything.
      var upgradeAttempts = 0;
      final peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 19193);
      peer.listen((request) async {
        upgradeAttempts++;
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      addTearDown(() => peer.close(force: true));

      await denied.start();
      refusals.clear();

      final linked = await denied.connectToPeer(address: '127.0.0.1', port: 19193);

      expect(linked, isFalse);
      expect(upgradeAttempts, 0, reason: 'the peer answered; nothing must have asked');
      expect(denied.activePeers, isEmpty);
      expect(refusals, hasLength(1),
          reason: 'an operator who typed an address is owed an answer');
      expect(refusals.single, contains('127.0.0.1:19193'));
    });
  });
}
