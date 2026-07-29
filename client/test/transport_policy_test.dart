import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/operator_identity.dart';
import 'package:vector_c2/services/mesh_client.dart';
import 'package:vector_c2/services/transport_policy.dart';

/// Transport policy: which nodes the client is willing to talk to in the clear.
///
/// The bug this guards against is not a crash. It is that `requireSecureTransport`
/// defaulted to false and nothing ever set it, so a build pointed at a plaintext
/// public node leaked routing metadata with no indication anything was wrong.
void main() {
  group('host classification', () {
    test('loopback literals and names are loopback', () {
      expect(classifyHost('127.0.0.1'), NodeLocality.loopback);
      expect(classifyHost('127.1.2.3'), NodeLocality.loopback);
      expect(classifyHost('::1'), NodeLocality.loopback);
      expect(classifyHost('localhost'), NodeLocality.loopback);
      expect(classifyHost('LOCALHOST'), NodeLocality.loopback);
      expect(classifyHost('node.localhost'), NodeLocality.loopback);
    });

    test('RFC1918, CGNAT and link-local literals are private', () {
      expect(classifyHost('10.0.0.5'), NodeLocality.privateNetwork);
      expect(classifyHost('192.168.1.20'), NodeLocality.privateNetwork);
      expect(classifyHost('172.16.0.1'), NodeLocality.privateNetwork);
      expect(classifyHost('172.31.255.254'), NodeLocality.privateNetwork);
      expect(classifyHost('169.254.10.10'), NodeLocality.privateNetwork);
      // Tailscale hands out 100.64/10.
      expect(classifyHost('100.101.102.103'), NodeLocality.privateNetwork);
    });

    test('addresses just outside the private ranges are public', () {
      // 172.15 and 172.32 bracket the /12 — an off-by-one here would either
      // refuse a legitimate LAN node or permit plaintext to a routable one.
      expect(classifyHost('172.15.0.1'), NodeLocality.publicNetwork);
      expect(classifyHost('172.32.0.1'), NodeLocality.publicNetwork);
      expect(classifyHost('192.169.1.1'), NodeLocality.publicNetwork);
      expect(classifyHost('11.0.0.1'), NodeLocality.publicNetwork);
      expect(classifyHost('100.63.0.1'), NodeLocality.publicNetwork);
      expect(classifyHost('100.128.0.1'), NodeLocality.publicNetwork);
      expect(classifyHost('8.8.8.8'), NodeLocality.publicNetwork);
    });

    test('IPv6 ULA and link-local are private, global unicast is public', () {
      expect(classifyHost('fd12:3456::1'), NodeLocality.privateNetwork);
      expect(classifyHost('fc00::1'), NodeLocality.privateNetwork);
      expect(classifyHost('fe80::1'), NodeLocality.privateNetwork);
      expect(classifyHost('2001:4860:4860::8888'), NodeLocality.publicNetwork);
    });

    test('IPv4-mapped IPv6 is judged as the address it carries', () {
      // ::ffff:127.0.0.1 would otherwise read as public and a loopback node
      // would be refused, or worse, a mapped public address permitted.
      expect(classifyHost('::ffff:127.0.0.1'), NodeLocality.loopback);
      expect(classifyHost('::ffff:192.168.0.1'), NodeLocality.privateNetwork);
      expect(classifyHost('::ffff:8.8.8.8'), NodeLocality.publicNetwork);
    });

    test('bracketed IPv6 authority is tolerated', () {
      expect(classifyHost('[::1]'), NodeLocality.loopback);
    });

    test('private-use name suffixes and single-label hosts are private', () {
      expect(classifyHost('nas.local'), NodeLocality.privateNetwork);
      expect(classifyHost('field-router.lan'), NodeLocality.privateNetwork);
      expect(classifyHost('relay.internal'), NodeLocality.privateNetwork);
      expect(classifyHost('node.home.arpa'), NodeLocality.privateNetwork);
      // A single label cannot be a public FQDN.
      expect(classifyHost('nas'), NodeLocality.privateNetwork);
    });

    test('a routable name is public', () {
      expect(classifyHost('c2.example.com'), NodeLocality.publicNetwork);
      expect(classifyHost('relay.example.co.uk'), NodeLocality.publicNetwork);
      // Not ".local" — a substring match here would classify it as private.
      expect(classifyHost('local.example.com'), NodeLocality.publicNetwork);
      expect(classifyHost('notlocal.com'), NodeLocality.publicNetwork);
    });

    test('empty host is treated as public rather than trusted', () {
      expect(classifyHost(''), NodeLocality.publicNetwork);
      expect(classifyHost('   '), NodeLocality.publicNetwork);
    });
  });

  group('isTransportAllowed', () {
    test('https and wss are always allowed', () {
      for (final policy in TransportPolicy.values) {
        expect(isTransportAllowed('https://c2.example.com', policy), isTrue);
        expect(isTransportAllowed('wss://c2.example.com/ws', policy), isTrue);
      }
    });

    test('default permits LAN plaintext but refuses routable plaintext', () {
      const policy = TransportPolicy.privateNetworkPlaintext;
      expect(isTransportAllowed('http://127.0.0.1:8080', policy), isTrue);
      expect(isTransportAllowed('http://192.168.1.20:8080', policy), isTrue);
      expect(isTransportAllowed('http://nas.local:8080', policy), isTrue);
      expect(isTransportAllowed('http://c2.example.com', policy), isFalse);
      expect(isTransportAllowed('http://8.8.8.8:8080', policy), isFalse);
    });

    test('tlsOnly refuses plaintext even on the LAN', () {
      const policy = TransportPolicy.tlsOnly;
      expect(isTransportAllowed('http://127.0.0.1:8080', policy), isFalse);
      expect(isTransportAllowed('http://192.168.1.20:8080', policy), isFalse);
      expect(isTransportAllowed('https://nas.local:8443', policy), isTrue);
    });

    test('allowAllPlaintext is the escape hatch for split-horizon DNS', () {
      const policy = TransportPolicy.allowAllPlaintext;
      expect(isTransportAllowed('http://c2.example.com', policy), isTrue);
    });

    test('a scheme that is neither http nor https is refused outright', () {
      for (final policy in TransportPolicy.values) {
        expect(isTransportAllowed('ftp://c2.example.com', policy), isFalse);
        expect(isTransportAllowed('file:///etc/passwd', policy), isFalse);
      }
    });
  });

  group('relay trust anchor', () {
    // A genuine CA certificate, so the happy path is actually exercised rather
    // than skipped. Expiry is irrelevant here: loading a trust anchor parses it
    // and does not validate dates. Regenerate with:
    //   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    //     -sha256 -days 36500 -nodes -keyout /dev/null -out ca.crt \
    //     -subj "/CN=Vector C2 Test CA (fixture)" \
    //     -addext "basicConstraints=critical,CA:TRUE" \
    //     -addext "keyUsage=critical,keyCertSign,cRLSign"
    const caPem = '''
-----BEGIN CERTIFICATE-----
MIIBszCCAVmgAwIBAgIUbfVGlY1rprwUSSf21KaysG8+s6gwCgYIKoZIzj0EAwIw
JjEkMCIGA1UEAwwbVmVjdG9yIEMyIFRlc3QgQ0EgKGZpeHR1cmUpMCAXDTI2MDcy
OTIzMDEzOFoYDzIxMjYwNzA1MjMwMTM4WjAmMSQwIgYDVQQDDBtWZWN0b3IgQzIg
VGVzdCBDQSAoZml4dHVyZSkwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASzlZnu
CFdiTG+2zNRDsMjLj1fhdEfv9TywNuDG/OhoRbs4yHQHblzqvr80SMdcl1BrnR49
eZzBVyengCgByFxeo2MwYTAdBgNVHQ4EFgQUj+3QPMvflBphZ3ISWmNvYq5IQ7Yw
HwYDVR0jBBgwFoAUj+3QPMvflBphZ3ISWmNvYq5IQ7YwDwYDVR0TAQH/BAUwAwEB
/zAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwIDSAAwRQIgN3rXrzML8ee7I0cE
x4JedQyXvjhl6wTSMf374+52s+ACIQCsS7suOg0MnZFk6FW4d1X3SKMJ1KhyofnZ
vK3NBrW54w==
-----END CERTIFICATE-----
''';

    test('an empty define means platform roots only', () {
      expect(relayTrustContext(''), isNull);
      expect(relayTrustContext('   '), isNull);
    });

    test('non-base64 is rejected rather than silently ignored', () {
      // Silently ignoring it would leave every pinned node looking unreachable.
      expect(
        () => relayTrustContext('this is not base64 !!!'),
        throwsA(isA<RelayTrustAnchorInvalid>()),
      );
    });

    test('base64 that is not a certificate is rejected', () {
      expect(
        () => relayTrustContext(base64Encode(utf8.encode('hello world'))),
        throwsA(isA<RelayTrustAnchorInvalid>()),
      );
    });

    test('a PEM that will not parse is rejected', () {
      const truncated = '-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----\n';
      expect(
        () => relayTrustContext(base64Encode(utf8.encode(truncated))),
        throwsA(isA<RelayTrustAnchorInvalid>()),
      );
    });

    test('the failure names the problem so it can be shown to an operator', () {
      try {
        relayTrustContext('%%%not-base64%%%');
        fail('expected RelayTrustAnchorInvalid');
      } on RelayTrustAnchorInvalid catch (e) {
        expect(e.detail, isNotEmpty);
        expect(e.toString(), contains('RelayTrustAnchorInvalid'));
      }
    });

    test('a well-formed CA yields a context', () {
      // Guards the happy path: if setTrustedCertificatesBytes started throwing
      // on valid input, every pinned deployment would refuse to start.
      final ctx = relayTrustContext(base64Encode(utf8.encode(caPem)));
      expect(ctx, isNotNull);
    });
  });

  group('MeshClient honours the policy against a real socket', () {
    // Mocking the probe would prove nothing: the defect being guarded against
    // is that a *reachable* plaintext node gets used anyway. So stand up an
    // actual node that answers /ping and check the client still walks away.
    late HttpServer server;
    var pingCount = 0;

    setUp(() async {
      pingCount = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        if (request.uri.path == '/ping') {
          pingCount++;
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'node_id': 'test-node'}));
        } else {
          request.response.statusCode = 404;
        }
        request.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    test('a reachable loopback node is probed under the default policy', () async {
      final identity = await OperatorIdentity.forTesting();
      final client = MeshClient(
        identity: identity,
        seedNodeUrls: ['http://127.0.0.1:${server.port}'],
      );

      // Connecting needs the Ed25519 handshake this bare server does not speak,
      // so assert on the probe reaching it rather than on a completed session.
      //
      // This also covers a defect found while writing it: a host that answers
      // /ping but refuses the /ws upgrade failed the auth completer before
      // anything awaited it, and the unobserved error failed the whole suite.
      // Remove the `catchError` sink in MeshClient._connectToNode and this test
      // goes red with "Bad state: socket closed during authentication".
      client.start();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await client.dispose();

      expect(pingCount, greaterThan(0),
          reason: 'loopback plaintext must remain usable — the LAN and '
              'isolated-network deployments depend on it');
    });

    test('a reachable plaintext node is never probed under tlsOnly', () async {
      final identity = await OperatorIdentity.forTesting();
      final refusals = <String>[];
      final client = MeshClient(
        identity: identity,
        seedNodeUrls: ['http://127.0.0.1:${server.port}'],
        transportPolicy: TransportPolicy.tlsOnly,
      );
      final sub = client.transportRefusals.listen(refusals.add);

      client.start();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await sub.cancel();
      await client.dispose();

      expect(pingCount, 0,
          reason: 'the node answered /ping; the client must not have asked');
      expect(client.isConnected, isFalse);
      expect(refusals, hasLength(1),
          reason: 'a skipped seed must be reported, or it looks like an outage');
      expect(refusals.single, contains('127.0.0.1'));
    });

    test('a refusal is reported once, not on every probe tick', () async {
      final identity = await OperatorIdentity.forTesting();
      final refusals = <String>[];
      final client = MeshClient(
        identity: identity,
        seedNodeUrls: ['http://c2.example.com'],
      );
      final sub = client.transportRefusals.listen(refusals.add);

      // Reconnect backoff re-probes quickly at first, so several attempts land
      // inside this window.
      client.start();
      await Future<void>.delayed(const Duration(seconds: 3));
      await sub.cancel();
      await client.dispose();

      expect(refusals, hasLength(1));
    });
  });
}
