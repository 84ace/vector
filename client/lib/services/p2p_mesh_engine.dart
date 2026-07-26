import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

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

  String get endpoint => 'http://$address:$port';
}

/// P2PMeshEngine enables pure device-to-device communications on isolated networks
/// with ZERO dedicated server or backend software required.
class P2PMeshEngine {
  final String myOperatorId;
  final int p2pPort;

  HttpServer? _server;
  RawDatagramSocket? _udpSocket;
  Timer? _announcementTimer;

  final Map<String, PeerDevice> _discoveredPeers = {};
  final Map<String, WebSocket> _peerSockets = {};

  final StreamController<C2Message> _incomingP2PMessageController =
      StreamController<C2Message>.broadcast();
  final StreamController<List<PeerDevice>> _discoveredPeersController =
      StreamController<List<PeerDevice>>.broadcast();

  Stream<C2Message> get incomingP2PMessages =>
      _incomingP2PMessageController.stream;
  Stream<List<PeerDevice>> get discoveredPeers =>
      _discoveredPeersController.stream;

  Map<String, PeerDevice> get activePeers => _discoveredPeers;

  P2PMeshEngine({
    required this.myOperatorId,
    this.p2pPort = 9090,
  });

  /// Starts embedded P2P server and UDP mDNS multicast peer discovery.
  Future<void> start() async {
    try {
      // 1. Bind local P2P HTTP & WebSocket server on all local network interfaces
      _server = await HttpServer.bind(InternetAddress.anyIPv4, p2pPort);
      debugPrint('[P2P_ENGINE] Embedded server listening on port $p2pPort');
      _listenHttpServer();

      // 2. Bind UDP socket for local subnet multicast discovery
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        9091,
        reuseAddress: true,
        reusePort: true,
      );
      _udpSocket?.broadcastEnabled = true;
      _listenUdpDiscovery();

      // 3. Periodically announce presence to local isolated network
      _announcementTimer =
          Timer.periodic(const Duration(seconds: 4), (_) => _announcePresence());

      _announcePresence();
    } catch (e) {
      debugPrint('[P2P_ENGINE ERROR] Start failed: $e');
    }
  }

  void stop() {
    _announcementTimer?.cancel();
    _udpSocket?.close();
    _server?.close(force: true);
    for (final sock in _peerSockets.values) {
      sock.close();
    }
    _peerSockets.clear();
  }

  void _listenHttpServer() {
    _server?.listen((HttpRequest request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final senderId = request.uri.queryParameters['operator_id'] ?? 'unknown';
        debugPrint('[P2P_ENGINE] Incoming WebSocket upgrade from senderId=$senderId');
        final socket = await WebSocketTransformer.upgrade(request);
        _peerSockets[senderId] = socket;

        if (senderId.isNotEmpty && senderId != 'unknown' && senderId != myOperatorId) {
          final peerIp = request.connectionInfo?.remoteAddress.address ?? '';
          final peer = PeerDevice(
            operatorId: senderId,
            address: peerIp,
            port: p2pPort,
            lastSeen: DateTime.now(),
          );
          _discoveredPeers[senderId] = peer;
          _discoveredPeersController.add(_discoveredPeers.values.toList());
        }

        socket.listen(
          (data) {
            try {
              debugPrint('[P2P_ENGINE] Received direct P2P data: $data');
              final Map<String, dynamic> jsonMap = jsonDecode(data);
              final msg = C2Message.fromEnvelopeJson(jsonMap, myOperatorId);
              _incomingP2PMessageController.add(msg);
            } catch (e) {
              debugPrint('[P2P_ENGINE ERROR] Parse error: $e');
            }
          },
          onDone: () => _peerSockets.remove(senderId),
          onError: (_) => _peerSockets.remove(senderId),
        );
      } else if (request.uri.path == '/ping') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'mode': 'PURE_P2P_DEVICE',
            'operator_id': myOperatorId,
            'status': 'ONLINE',
          }));
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });
  }

  void _listenUdpDiscovery() {
    _udpSocket?.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        final dg = _udpSocket?.receive();
        if (dg == null) return;
        try {
          final payload = utf8.decode(dg.data);
          final jsonMap = jsonDecode(payload);
          final peerOpId = jsonMap['operator_id'] ?? '';
          final peerPort = jsonMap['port'] ?? p2pPort;

          if (peerOpId.isNotEmpty && peerOpId != myOperatorId) {
            final peerIp = dg.address.address;
            final peer = PeerDevice(
              operatorId: peerOpId,
              address: peerIp,
              port: peerPort,
              lastSeen: DateTime.now(),
            );

            _discoveredPeers[peerOpId] = peer;
            _discoveredPeersController.add(_discoveredPeers.values.toList());

            // Auto-connect direct WebSocket stream to newly discovered peer device
            _ensureDirectPeerConnection(peer);
          }
        } catch (_) {}
      }
    });
  }

  void _announcePresence() {
    if (_udpSocket == null) return;
    try {
      _udpSocket!.broadcastEnabled = true;
      final payload = jsonEncode({
        'c2_p2p': 'ANNOUNCE',
        'operator_id': myOperatorId,
        'port': p2pPort,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final bytes = utf8.encode(payload);

      _udpSocket!.send(bytes, InternetAddress('255.255.255.255'), 9091);
    } catch (e) {
      debugPrint('[P2P_ENGINE UDP ANNOUNCE HANDLED]: $e');
    }
  }

  Future<void> _ensureDirectPeerConnection(PeerDevice peer) async {
    if (_peerSockets.containsKey(peer.operatorId)) return;

    try {
      final wsUrl = 'ws://${peer.address}:${peer.port}/ws?operator_id=$myOperatorId';
      debugPrint('[P2P_ENGINE] Connecting direct socket to peer: $wsUrl');
      final socket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 3));
      _peerSockets[peer.operatorId] = socket;

      socket.listen(
        (data) {
          try {
            debugPrint('[P2P_ENGINE] Received direct P2P socket data: $data');
            final Map<String, dynamic> jsonMap = jsonDecode(data);
            final msg = C2Message.fromEnvelopeJson(jsonMap, myOperatorId);
            _incomingP2PMessageController.add(msg);
          } catch (_) {}
        },
        onDone: () => _peerSockets.remove(peer.operatorId),
        onError: (_) => _peerSockets.remove(peer.operatorId),
      );
    } catch (e) {
      debugPrint('[P2P_ENGINE ERROR] Direct peer connect failed: $e');
    }
  }

  /// Sends E2EE message envelope directly to connected peer devices without any backend server.
  bool sendP2PDirectMessage(C2Message message) {
    debugPrint('[P2P_ENGINE OUTBOUND] sendP2PDirectMessage: type=${message.type}, recipient=${message.recipientId}, peerSockets=${_peerSockets.keys.toList()}');
    if (_peerSockets.isEmpty) return false;
    final jsonStr = jsonEncode(message.toEnvelopeJson());
    bool delivered = false;

    for (final entry in _peerSockets.entries) {
      // Send to recipient, or send to all peers if recipient is unspecified / group / broadcast / single connection
      if (message.recipientId == null ||
          message.recipientId == entry.key ||
          _peerSockets.length == 1 ||
          message.type == MessageType.broadcast ||
          message.type == MessageType.chatGroup) {
        try {
          entry.value.add(jsonStr);
          delivered = true;
        } catch (_) {}
      }
    }
    return delivered;
  }

  /// Broadcasts E2EE message to all connected P2P mesh sockets
  bool broadcastP2PMessage(C2Message message) {
    if (_peerSockets.isEmpty) return false;
    final jsonStr = jsonEncode(message.toEnvelopeJson());
    for (final socket in _peerSockets.values) {
      try {
        socket.add(jsonStr);
      } catch (_) {}
    }
    return true;
  }
}
