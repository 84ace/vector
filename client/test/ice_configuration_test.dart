import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/services/ice_configuration.dart';

/// ICE configuration: the TURN decision, made explicit.
///
/// The standing decision is no TURN by default — a call with no direct path
/// fails visibly rather than silently relaying media through a third party.
/// These tests pin that default down so it cannot drift, and check that when a
/// deployment does opt in, the fact is surfaced rather than buried.
void main() {
  IceConfiguration configure({
    String stun = 'stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302',
    String turnUrls = '',
    String turnUsername = '',
    String turnCredential = '',
  }) =>
      IceConfiguration.fromDefines(
        stunServers: stun,
        turnUrls: turnUrls,
        turnUsername: turnUsername,
        turnCredential: turnCredential,
      );

  group('defaults', () {
    test('no TURN is configured, so media is never relayed', () {
      final ice = configure();
      expect(ice.turnServers, isEmpty);
      expect(ice.relaysMedia, isFalse);
    });

    test('the default STUN servers are carried through in order', () {
      final ice = configure();
      expect(ice.stunUrls, [
        'stun:stun.l.google.com:19302',
        'stun:stun1.l.google.com:19302',
      ]);
      expect(ice.toRtcIceServers(), [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ]);
    });

    test('public STUN is disclosed as an advisory', () {
      // Placing a call tells Google this device's address. That is the current
      // default and it should not be silent.
      final ice = configure();
      expect(ice.usesPublicStun, isTrue);
      expect(ice.advisories, hasLength(1));
      expect(ice.advisories.single, contains('public STUN'));
    });
  });

  group('isolated network', () {
    test('STUN can be disabled entirely, leaving host candidates', () {
      final ice = configure(stun: '');
      expect(ice.stunUrls, isEmpty);
      expect(ice.toRtcIceServers(), isEmpty);
      expect(ice.usesPublicStun, isFalse);
      expect(ice.advisories, isEmpty,
          reason: 'a self-contained deployment makes no privacy trade to report');
    });

    test('a private STUN server raises no public-STUN advisory', () {
      final ice = configure(stun: 'stun:nas.local:3478');
      expect(ice.usesPublicStun, isFalse);
      expect(ice.advisories, isEmpty);
    });
  });

  group('opting in to TURN', () {
    test('TURN servers carry credentials into the RTC configuration', () {
      final ice = configure(
        stun: '',
        turnUrls: 'turn:relay.example.com:3478',
        turnUsername: 'operator',
        turnCredential: 's3cret',
      );

      expect(ice.relaysMedia, isTrue);
      expect(ice.toRtcIceServers(), [
        {
          'urls': 'turn:relay.example.com:3478',
          'username': 'operator',
          'credential': 's3cret',
        },
      ]);
    });

    test('several TURN servers are supported', () {
      final ice = configure(
        turnUrls: 'turn:a.example.com:3478,turns:b.example.com:5349',
        turnUsername: 'op',
        turnCredential: 'pw',
      );
      expect(ice.turnServers.map((t) => t.url), [
        'turn:a.example.com:3478',
        'turns:b.example.com:5349',
      ]);
    });

    test('enabling TURN states what the relay learns', () {
      final ice = configure(
        stun: '',
        turnUrls: 'turn:relay.example.com:3478',
        turnUsername: 'op',
        turnCredential: 'pw',
      );

      expect(ice.advisories, hasLength(1));
      final advisory = ice.advisories.single;
      expect(advisory, contains('relay.example.com'));
      // The point of the advisory is the trade, not the hostname.
      expect(advisory, contains('addresses'));
      expect(advisory, contains('cannot listen'));
    });

    test('STUN comes before TURN so a direct path is preferred', () {
      // Ordering is not cosmetic: ICE tries candidates in priority order and a
      // relayed candidate should never win when a direct one is available.
      final ice = configure(
        stun: 'stun:nas.local:3478',
        turnUrls: 'turn:relay.example.com:3478',
        turnUsername: 'op',
        turnCredential: 'pw',
      );
      final urls = ice.toRtcIceServers().map((s) => s['urls'] as String).toList();
      expect(urls.first, startsWith('stun:'));
      expect(urls.last, startsWith('turn:'));
    });
  });

  group('parsing', () {
    test('whitespace and empty entries are tolerated', () {
      final ice = configure(stun: ' stun:a.local:3478 , , stun:b.local:3478 ,');
      expect(ice.stunUrls, ['stun:a.local:3478', 'stun:b.local:3478']);
    });

    test('a blank TURN url does not create a phantom relay', () {
      // A deploy script that sets TURN_USERNAME but leaves TURN_URLS empty must
      // not end up with relaysMedia true and an entry with no address.
      final ice = configure(turnUrls: '  ,  ', turnUsername: 'op', turnCredential: 'pw');
      expect(ice.turnServers, isEmpty);
      expect(ice.relaysMedia, isFalse);
    });
  });
}
