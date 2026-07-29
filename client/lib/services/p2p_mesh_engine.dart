import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../crypto/operator_identity.dart';
import '../models/c2_message.dart';

class PeerDevice {
  final String operatorId;
  final String address;
  final int port;
  final DateTime lastSeen;

  PeerDevice({
    required this.operatorId,
    required this.address,
    required this.port,
    required this.lastSeen,
  });

  PeerDevice touch() => PeerDevice(
        operatorId: operatorId,
        address: address,
        port: port,
        lastSeen: DateTime.now(),
      );
}

/// A live direct link to a peer device, with the identity it proved on connect.
class _PeerLink {
  final WebSocket socket;
  final String operatorId;
  final String signKey;

  _PeerLink(this.socket, this.operatorId, this.signKey);
}

/// P2PMeshEngine provides device-to-device communication on isolated networks
/// with no backend node present.
///
/// Every link is authenticated with the same Ed25519 challenge/response the
/// relay uses, in both directions. Without that, this listener — which is bound
/// to all interfaces on every operator's handset — accepts messages from
/// anything on the network that can open a socket.
class P2PMeshEngine {
  static const _discoveryPort = 9091;
  static const _authTimeout = Duration(seconds: 10);
  static const _announceInterval = Duration(seconds: 10);
  static const _peerTTL = Duration(seconds: 60);
  static const _maxFrameBytes = 512 * 1024;
  static const _maxPeers = 64;
  static const _maxProvisionalLinks = 8;

  final OperatorIdentity identity;
  final int p2pPort;

  /// Returns true if [operatorId] is a paired contact.
  ///
  /// Unpaired operators may still hold a link — pairing has to travel somehow —
  /// but it is provisional: capped in number, and restricted by [_dispatchFrame]
  /// to carrying a pairing request and nothing else.
  final bool Function(String operatorId) isPairedContact;

  HttpServer? _server;
  RawDatagramSocket? _udpSocket;
  Timer? _announcementTimer;
  Timer? _reaperTimer;
  bool _announceEnabled;

  final Map<String, PeerDevice> _discoveredPeers = {};
  final Map<String, _PeerLink> _peerLinks = {};
  final Set<String> _dialing = {};

  final _incomingController = StreamController<C2Message>.broadcast();
  final _peersController = StreamController<List<PeerDevice>>.broadcast();

  Stream<C2Message> get incomingP2PMessages => _incomingController.stream;
  Stream<List<PeerDevice>> get discoveredPeers => _peersController.stream;
  Map<String, PeerDevice> get activePeers => Map.unmodifiable(_discoveredPeers);

  P2PMeshEngine({
    required this.identity,
    this.p2pPort = 9090,
    required this.isPairedContact,
    bool announceEnabled = true,
  }) : _announceEnabled = announceEnabled;

  String get myOperatorId => identity.operatorId;

  /// Presence beacons name this operator to the whole subnet every few seconds.
  /// Operators working near untrusted networks can turn that off and rely on
  /// the relay instead.
  set announceEnabled(bool enabled) {
    _announceEnabled = enabled;
    if (!enabled) {
      _announcementTimer?.cancel();
      _announcementTimer = null;
    } else if (_udpSocket != null && _announcementTimer == null) {
      _announcementTimer = Timer.periodic(_announceInterval, (_) => _announcePresence());
      _announcePresence();
    }
  }

  /// Brings up the direct-link server and, separately, subnet discovery.
  ///
  /// The two are started independently on purpose. They used to share one
  /// try/catch, so a failure binding the discovery socket silently skipped the
  /// announce timer and the peer reaper while the link server carried on
  /// looking healthy — the device simply never found anyone and never said why.
  Future<void> start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, p2pPort);
      debugPrint('[P2P_ENGINE] Listening on port $p2pPort');
      _listenHttpServer();
    } catch (e) {
      debugPrint('[P2P_ENGINE] Could not bind link server on $p2pPort: $e');
      return; // Without this there is no P2P at all.
    }

    await _startDiscovery();

    _reaperTimer = Timer.periodic(const Duration(seconds: 20), (_) => _reapStalePeers());
  }

  /// Binds the UDP discovery socket, degrading rather than failing.
  ///
  /// `reusePort` is unsupported on Android/Linux and throws there, so it is
  /// attempted and then retried without. Losing discovery only costs automatic
  /// peer finding — links can still be dialled directly.
  Future<void> _startDiscovery() async {
    for (final withReusePort in [true, false]) {
      try {
        _udpSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          _discoveryPort,
          reuseAddress: true,
          reusePort: withReusePort,
        );
        _udpSocket?.broadcastEnabled = true;
        _listenUdpDiscovery();

        if (_announceEnabled) {
          _announcementTimer = Timer.periodic(_announceInterval, (_) => _announcePresence());
          _announcePresence();
        }

        debugPrint('[P2P_ENGINE] Discovery active on $_discoveryPort'
            '${withReusePort ? '' : ' (without reusePort)'}');
        return;
      } catch (e) {
        if (withReusePort) continue; // Retry without it.
        debugPrint('[P2P_ENGINE] Discovery unavailable: $e — peers must be '
            'dialled directly, automatic discovery is off.');
      }
    }
  }

  Future<void> stop() async {
    _announcementTimer?.cancel();
    _announcementTimer = null;
    _reaperTimer?.cancel();
    _reaperTimer = null;

    _udpSocket?.close();
    _udpSocket = null;

    await _server?.close(force: true);
    _server = null;

    for (final link in _peerLinks.values) {
      await link.socket.close();
    }
    _peerLinks.clear();
    _discoveredPeers.clear();
    _dialing.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _incomingController.close();
    await _peersController.close();
  }

  void _listenHttpServer() {
    _server?.listen((HttpRequest request) async {
      try {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          if (_peerLinks.length >= _maxPeers) {
            request.response.statusCode = HttpStatus.serviceUnavailable;
            await request.response.close();
            return;
          }
          final socket = await WebSocketTransformer.upgrade(request);
          final remote = request.connectionInfo?.remoteAddress.address ?? '';
          try {
            await _performMutualAuth(socket, remote);
          } catch (_) {
            // Already logged and closed by the handshake.
          }
          return;
        }

        if (request.uri.path == '/ping') {
          // Deliberately anonymous: this endpoint is reachable by anything on
          // the network, so it does not disclose who owns the device.
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'mode': 'PURE_P2P_DEVICE', 'status': 'ONLINE'}));
          await request.response.close();
          return;
        }

        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } catch (e) {
        debugPrint('[P2P_ENGINE] Request handling error: $e');
      }
    });
  }

  /// Runs the mutual challenge/response handshake over [socket].
  ///
  /// Symmetric by design: both ends issue a challenge and both must answer.
  /// The dialer needs this as much as the listener — otherwise it would happily
  /// register whichever host answered a broadcast as the peer it was looking
  /// for, and route that operator's traffic there.
  ///
  /// [expectedPeerId], when set, additionally requires the proven identity to
  /// match the peer we intended to reach.
  Future<void> _performMutualAuth(
    WebSocket socket,
    String remoteAddress, {
    String? expectedPeerId,
  }) async {
    final myNonce = _randomNonce();
    final completer = Completer<_PeerLink>();
    StreamSubscription? sub;
    _PeerLink? established;

    void fail(Object error) {
      if (!completer.isCompleted) completer.completeError(error);
    }

    sub = socket.listen(
      (dynamic data) async {
        final link = established;
        if (link != null) {
          _dispatchFrame(data, link.operatorId);
          return;
        }
        try {
          final frame = jsonDecode(data as String) as Map<String, dynamic>;
          switch (frame['type']) {
            case 'AUTH_CHALLENGE':
              final nonce = base64Decode(frame['nonce'] as String);
              socket.add(jsonEncode({
                'type': 'AUTH_RESPONSE',
                'operator_id': identity.operatorId,
                'sign_key': identity.signPublicKey,
                'signature': await identity.sign(nonce),
              }));

            case 'AUTH_RESPONSE':
              final proven = await _verifyPeerAuth(frame, myNonce, socket);
              if (proven == null) {
                fail(StateError('peer failed our challenge'));
                return;
              }
              if (expectedPeerId != null && proven.operatorId != expectedPeerId) {
                fail(StateError('peer identity does not match announcement'));
                return;
              }
              established = proven;
              completer.complete(proven);
          }
        } catch (e) {
          fail(e);
        }
      },
      onDone: () => fail(StateError('peer closed during authentication')),
      onError: fail,
    );

    socket.add(jsonEncode({'type': 'AUTH_CHALLENGE', 'nonce': base64Encode(myNonce)}));

    try {
      final link = await completer.future.timeout(_authTimeout);
      _registerLink(link, remoteAddress, sub);
    } catch (e) {
      debugPrint('[P2P_ENGINE] Handshake with $remoteAddress failed: $e');
      await sub.cancel();
      await socket.close();
      rethrow;
    }
  }

  /// Verifies an AUTH_RESPONSE against [nonce] and returns the peer's proven
  /// identity, or null if the proof does not hold.
  Future<_PeerLink?> _verifyPeerAuth(
    Map<String, dynamic> frame,
    List<int> nonce,
    WebSocket socket,
  ) async {
    final signKey = frame['sign_key'] as String?;
    final claimedId = frame['operator_id'] as String?;
    final signature = frame['signature'] as String?;
    if (signKey == null || claimedId == null || signature == null) return null;

    String derived;
    try {
      derived = OperatorIdentity.deriveOperatorId(signKey);
    } catch (_) {
      return null;
    }
    if (derived != claimedId || derived == identity.operatorId) return null;
    if (!await OperatorIdentity.verify(nonce, signature, signKey)) return null;

    // Unpaired operators are allowed to hold a link, but only a provisional
    // one: _dispatchFrame lets nothing but a pairing request across it.
    //
    // Refusing them outright — as this did originally — made pairing
    // impossible on an isolated network, because P2P is the only transport a
    // PAIR_REQUEST can travel when no relay node is reachable, and neither side
    // is a contact of the other yet at that point.
    if (!isPairedContact(derived) && _provisionalLinkCount >= _maxProvisionalLinks) {
      debugPrint('[P2P_ENGINE] Too many provisional links; refused $derived');
      return null;
    }

    return _PeerLink(socket, derived, signKey);
  }

  /// Links held by operators we have not paired with. Bounded separately from
  /// paired links so a hostile network cannot exhaust the peer table.
  int get _provisionalLinkCount =>
      _peerLinks.keys.where((id) => !isPairedContact(id)).length;

  void _registerLink(_PeerLink link, String remoteAddress, StreamSubscription sub) {
    // Retire any previous link for this operator instead of leaking it.
    final existing = _peerLinks[link.operatorId];
    if (existing != null && existing.socket != link.socket) {
      existing.socket.close();
    }
    _peerLinks[link.operatorId] = link;

    _discoveredPeers[link.operatorId] = PeerDevice(
      operatorId: link.operatorId,
      address: remoteAddress,
      port: p2pPort,
      lastSeen: DateTime.now(),
    );
    _emitPeers();

    // Only tear down the map entry if it still points at *this* socket; a
    // reconnect that replaced it must not be evicted by the old link's close.
    void detach() {
      if (identical(_peerLinks[link.operatorId]?.socket, link.socket)) {
        _peerLinks.remove(link.operatorId);
        _emitPeers();
      }
    }

    sub.onDone(detach);
    sub.onError((Object _) => detach());

    debugPrint('[P2P_ENGINE] Authenticated peer link: ${link.operatorId} @ $remoteAddress');
  }

  /// Hands an inbound frame to the app, enforcing what this link may carry.
  ///
  /// A link from an operator we have not paired with may deliver exactly one
  /// kind of envelope: a pairing request. Everything else is dropped here, so
  /// allowing the link to exist does not let a stranger inject chat, telemetry,
  /// call control or unpair commands. Those would fail signature or decryption
  /// checks further up anyway; refusing them at the edge keeps the boundary
  /// obvious and cheap.
  void _dispatchFrame(dynamic data, String fromOperatorId) {
    try {
      if (data is String && data.length > _maxFrameBytes) return;
      final jsonMap = jsonDecode(data as String) as Map<String, dynamic>;
      if (jsonMap.containsKey('type') && !jsonMap.containsKey('encrypted_body')) return;

      final msg = C2Message.fromEnvelopeJson(jsonMap, identity.operatorId);

      // The envelope must come from the operator that authenticated this link.
      if (msg.senderId != fromOperatorId) {
        debugPrint('[P2P_ENGINE] Dropped frame: sender does not match link identity');
        return;
      }

      if (!isPairedContact(fromOperatorId) && msg.type != MessageType.pairRequest) {
        debugPrint('[P2P_ENGINE] Dropped ${msg.type} from unpaired $fromOperatorId');
        return;
      }

      if (!_incomingController.isClosed) _incomingController.add(msg);
    } catch (e) {
      debugPrint('[P2P_ENGINE] Discarded invalid frame: $e');
    }
  }

  void _listenUdpDiscovery() {
    _udpSocket?.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final dg = _udpSocket?.receive();
      if (dg == null) return;

      try {
        final jsonMap = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (jsonMap['c2_p2p'] != 'ANNOUNCE') return;

        final signKey = jsonMap['sign_key'] as String?;
        if (signKey == null) return;

        // The announcement is only a hint about where to dial; identity is
        // settled by the challenge on the link itself. Unpaired peers are
        // dialled too — that is how a pairing request reaches a device that has
        // never heard of us — but the link they get is provisional and capped.
        final peerId = OperatorIdentity.deriveOperatorId(signKey);
        if (peerId == identity.operatorId) return;
        if (!isPairedContact(peerId) && _provisionalLinkCount >= _maxProvisionalLinks) {
          return;
        }

        final port = jsonMap['port'];
        final peer = PeerDevice(
          operatorId: peerId,
          address: dg.address.address,
          port: port is int ? port : p2pPort,
          lastSeen: DateTime.now(),
        );

        _discoveredPeers[peerId] = peer;
        _emitPeers();
        _ensureDirectPeerConnection(peer);
      } catch (_) {
        // Malformed datagram; ignore.
      }
    });
  }

  void _announcePresence() {
    final socket = _udpSocket;
    if (socket == null || !_announceEnabled) return;

    try {
      socket.broadcastEnabled = true;
      final payload = jsonEncode({
        'c2_p2p': 'ANNOUNCE',
        'sign_key': identity.signPublicKey,
        'port': p2pPort,
      });
      socket.send(utf8.encode(payload), InternetAddress('255.255.255.255'), _discoveryPort);
    } catch (e) {
      debugPrint('[P2P_ENGINE] Announce failed: $e');
    }
  }

  /// Dials a peer at a known address, bypassing UDP discovery.
  ///
  /// Used when an operator enters an address by hand, and by the integration
  /// tests, which need a deterministic link rather than waiting on a subnet
  /// broadcast. Returns true once the mutual handshake has completed.
  Future<bool> connectToPeer({required String address, int? port}) async {
    final target = PeerDevice(
      operatorId: '',
      address: address,
      port: port ?? p2pPort,
      lastSeen: DateTime.now(),
    );

    try {
      final socket = await WebSocket.connect('ws://${target.address}:${target.port}/ws')
          .timeout(const Duration(seconds: 5));
      await _performMutualAuth(socket, target.address);
      return true;
    } catch (e) {
      debugPrint('[P2P_ENGINE] Manual dial to ${target.address} failed: $e');
      return false;
    }
  }

  Future<void> _ensureDirectPeerConnection(PeerDevice peer) async {
    if (_peerLinks.containsKey(peer.operatorId)) return;
    if (_peerLinks.length >= _maxPeers) return;
    if (!_dialing.add(peer.operatorId)) return; // Dial already in flight.

    try {
      final socket = await WebSocket.connect(
        'ws://${peer.address}:${peer.port}/ws',
      ).timeout(const Duration(seconds: 3));

      await _performMutualAuth(socket, peer.address, expectedPeerId: peer.operatorId);
    } catch (e) {
      debugPrint('[P2P_ENGINE] Dial to ${peer.operatorId} failed: $e');
    } finally {
      _dialing.remove(peer.operatorId);
    }
  }

  void _reapStalePeers() {
    final cutoff = DateTime.now().subtract(_peerTTL);
    var changed = false;

    _discoveredPeers.removeWhere((id, peer) {
      final stale = peer.lastSeen.isBefore(cutoff) && !_peerLinks.containsKey(id);
      if (stale) changed = true;
      return stale;
    });

    if (changed) _emitPeers();
  }

  void _emitPeers() {
    if (!_peersController.isClosed) {
      _peersController.add(_discoveredPeers.values.toList());
    }
  }

  List<int> _randomNonce() {
    final rnd = Random.secure();
    return List<int>.generate(32, (_) => rnd.nextInt(256));
  }

  /// Sends a signed envelope to its intended recipient only.
  ///
  /// Directed messages go to the addressed operator and nobody else. The old
  /// "if there is only one peer, send it there" shortcut delivered private
  /// traffic to whichever device happened to be connected.
  bool sendP2PDirectMessage(C2Message message) {
    if (_peerLinks.isEmpty) return false;
    final payload = jsonEncode(message.toEnvelopeJson());

    final recipientId = message.recipientId;
    final isTeamTraffic = recipientId == null ||
        message.type == MessageType.broadcast ||
        message.type == MessageType.chatGroup ||
        message.type == MessageType.telemetry ||
        message.type == MessageType.sosAlert ||
        message.type == MessageType.waypoint;

    if (!isTeamTraffic) {
      final link = _peerLinks[recipientId];
      if (link == null) return false;
      return _send(link, payload);
    }

    var delivered = false;
    for (final link in _peerLinks.values) {
      if (_send(link, payload)) delivered = true;
    }
    return delivered;
  }

  bool _send(_PeerLink link, String payload) {
    try {
      link.socket.add(payload);
      return true;
    } catch (e) {
      debugPrint('[P2P_ENGINE] Send to ${link.operatorId} failed: $e');
      return false;
    }
  }

  bool broadcastP2PMessage(C2Message message) => sendP2PDirectMessage(message);
}
