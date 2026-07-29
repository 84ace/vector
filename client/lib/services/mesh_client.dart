import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/operator_identity.dart';
import '../models/c2_message.dart';

class NodePingResult {
  final String nodeId;
  final String httpUrl;
  final String wsUrl;
  final int latencyMs;

  NodePingResult({
    required this.nodeId,
    required this.httpUrl,
    required this.wsUrl,
    required this.latencyMs,
  });
}

class MeshClient {
  static const _probeInterval = Duration(seconds: 30);
  static const _probeTimeout = Duration(seconds: 3);
  static const _authTimeout = Duration(seconds: 10);
  static const _maxBackoff = Duration(minutes: 2);

  final OperatorIdentity identity;
  final List<String> seedNodeUrls;

  /// When true, refuse to connect to a node over plaintext ws://.
  ///
  /// Envelope bodies are end-to-end encrypted either way, but plaintext
  /// transport exposes routing metadata — who is talking to whom, and when —
  /// which for this application is itself sensitive.
  final bool requireSecureTransport;

  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;

  String? activeNodeId;
  String? activeNodeUrl;
  int currentLatencyMs = 0;
  bool isConnected = false;

  final _incomingMessagesController = StreamController<C2Message>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();

  Stream<C2Message> get incomingMessages => _incomingMessagesController.stream;
  Stream<bool> get connectionState => _connectionStateController.stream;

  Timer? _probeTimer;
  Timer? _reconnectTimer;
  bool _probeInFlight = false;
  bool _stopped = false;
  int _consecutiveFailures = 0;

  /// Completes when the node accepts our signed challenge response. Frames that
  /// arrive before this completes are handshake frames, not envelopes.
  Completer<void>? _authCompleter;
  bool _authenticated = false;

  MeshClient({
    required this.identity,
    required this.seedNodeUrls,
    this.requireSecureTransport = false,
  });

  String get myOperatorId => identity.operatorId;

  void start() {
    _stopped = false;
    _probeAndConnectNearestNode();
    _probeTimer?.cancel();
    _probeTimer = Timer.periodic(_probeInterval, (_) => _probeAndConnectNearestNode());
  }

  Future<void> stop() async {
    _stopped = true;
    _probeTimer?.cancel();
    _reconnectTimer?.cancel();
    await _wsSubscription?.cancel();
    _wsSubscription = null;
    await _wsChannel?.sink.close();
    _wsChannel = null;
    _setConnected(false);
  }

  /// Releases stream controllers. Call from State.dispose.
  Future<void> dispose() async {
    await stop();
    await _incomingMessagesController.close();
    await _connectionStateController.close();
  }

  void _setConnected(bool connected) {
    if (isConnected == connected) return;
    isConnected = connected;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(connected);
    }
  }

  /// Probes candidate nodes concurrently and attaches to the lowest-latency one.
  ///
  /// Guarded against overlap: probing five unreachable seeds serially could take
  /// longer than the probe interval, so ticks piled up and each one raced to
  /// replace the socket the previous one had just opened.
  Future<void> _probeAndConnectNearestNode() async {
    if (_stopped || _probeInFlight) return;
    _probeInFlight = true;

    try {
      final results = await Future.wait(seedNodeUrls.map(_probeNode));
      final reachable = results.whereType<NodePingResult>().toList();

      if (reachable.isEmpty) {
        _setConnected(false);
        _scheduleReconnect();
        return;
      }

      reachable.sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
      final best = reachable.first;

      if (!isConnected || activeNodeId != best.nodeId) {
        await _connectToNode(best);
      } else {
        currentLatencyMs = best.latencyMs;
      }
    } finally {
      _probeInFlight = false;
    }
  }

  Future<NodePingResult?> _probeNode(String baseUrl) async {
    try {
      final uri = Uri.parse(baseUrl);
      if (requireSecureTransport && uri.scheme != 'https') {
        debugPrint('[MESH_CLIENT] Skipping $baseUrl: plaintext transport is disabled');
        return null;
      }

      final stopwatch = Stopwatch()..start();
      final response = await http.get(uri.replace(path: _joinPath(uri.path, 'ping'))).timeout(_probeTimeout);
      stopwatch.stop();

      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      final wsUri = uri.replace(
        scheme: uri.scheme == 'https' ? 'wss' : 'ws',
        path: _joinPath(uri.path, 'ws'),
      );

      return NodePingResult(
        nodeId: data['node_id'] as String? ?? 'unknown',
        httpUrl: baseUrl,
        wsUrl: wsUri.toString(),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } catch (_) {
      return null; // Node unreachable.
    }
  }

  static String _joinPath(String base, String segment) =>
      base.endsWith('/') ? '$base$segment' : '$base/$segment';

  Future<void> _connectToNode(NodePingResult node) async {
    await _wsSubscription?.cancel();
    _wsSubscription = null;
    await _wsChannel?.sink.close();
    _wsChannel = null;
    _setConnected(false);

    _authenticated = false;
    final auth = _authCompleter = Completer<void>();

    try {
      final channel = WebSocketChannel.connect(Uri.parse(node.wsUrl));
      await channel.ready.timeout(_authTimeout);
      _wsChannel = channel;

      // A WebSocketChannel stream is single-subscription, so the handshake runs
      // through the same listener the envelopes will use, gated on _authenticated.
      _wsSubscription = channel.stream.listen(
        _handleFrame,
        onError: (Object err) {
          debugPrint('[MESH_CLIENT] Socket error: $err');
          _handleDisconnect();
        },
        onDone: _handleDisconnect,
        cancelOnError: true,
      );

      // The node routes nothing for us until we prove we hold the key behind
      // our operator ID. Nothing is reported as connected until that lands.
      await auth.future.timeout(_authTimeout);

      activeNodeId = node.nodeId;
      activeNodeUrl = node.httpUrl;
      currentLatencyMs = node.latencyMs;
      _consecutiveFailures = 0;

      _setConnected(true);
      debugPrint('[MESH_CLIENT] Authenticated to node ${node.nodeId} (${node.latencyMs}ms)');
    } catch (e) {
      debugPrint('[MESH_CLIENT] Connect/auth failed for ${node.nodeId}: $e');
      await _wsChannel?.sink.close();
      _wsChannel = null;
      _handleDisconnect();
    }
  }

  void _handleFrame(dynamic rawMessage) {
    Map<String, dynamic> jsonMap;
    try {
      jsonMap = jsonDecode(rawMessage as String) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[MESH_CLIENT] Discarded unparseable frame: $e');
      return;
    }

    if (!_authenticated) {
      _handleHandshakeFrame(jsonMap);
      return;
    }

    try {
      final msg = C2Message.fromEnvelopeJson(jsonMap, identity.operatorId);
      if (!_incomingMessagesController.isClosed) {
        _incomingMessagesController.add(msg);
      }
    } catch (e) {
      // Includes unknown envelope types, which are rejected outright rather
      // than defaulting into an arbitrary handler.
      debugPrint('[MESH_CLIENT] Discarded invalid envelope: $e');
    }
  }

  /// Answers the node's challenge by signing its nonce with the identity key.
  void _handleHandshakeFrame(Map<String, dynamic> frame) {
    final auth = _authCompleter;

    switch (frame['type']) {
      case 'AUTH_CHALLENGE':
        final nonceB64 = frame['nonce'];
        if (nonceB64 is! String) {
          auth?.completeError(StateError('challenge carried no nonce'));
          return;
        }
        // Sign asynchronously; the reply goes out when the signature is ready.
        identity.sign(base64Decode(nonceB64)).then((signature) {
          _wsChannel?.sink.add(jsonEncode({
            'type': 'AUTH_RESPONSE',
            'operator_id': identity.operatorId,
            'sign_key': identity.signPublicKey,
            'signature': signature,
          }));
        }).catchError((Object e) {
          if (auth != null && !auth.isCompleted) auth.completeError(e);
        });

      case 'AUTH_RESULT':
        if (frame['ok'] == true) {
          _authenticated = true;
          if (auth != null && !auth.isCompleted) auth.complete();
        } else if (auth != null && !auth.isCompleted) {
          auth.completeError(StateError('node rejected authentication: ${frame['reason']}'));
        }

      default:
        if (auth != null && !auth.isCompleted) {
          auth.completeError(StateError('unexpected frame before authentication'));
        }
    }
  }

  void _handleDisconnect() {
    _wsSubscription?.cancel();
    _wsSubscription = null;
    _wsChannel = null;
    _authenticated = false;

    final auth = _authCompleter;
    if (auth != null && !auth.isCompleted) {
      auth.completeError(StateError('socket closed during authentication'));
    }
    _authCompleter = null;

    _setConnected(false);
    _scheduleReconnect();
  }

  /// Exponential backoff with jitter, so a node coming back up does not get
  /// stampeded by every field client reconnecting on the same cadence.
  void _scheduleReconnect() {
    if (_stopped) return;
    _reconnectTimer?.cancel();

    _consecutiveFailures = min(_consecutiveFailures + 1, 8);
    final base = Duration(seconds: 2 << (_consecutiveFailures - 1));
    final capped = base > _maxBackoff ? _maxBackoff : base;
    final jitterMs = Random().nextInt(1000);

    _reconnectTimer = Timer(
      Duration(milliseconds: capped.inMilliseconds + jitterMs),
      _probeAndConnectNearestNode,
    );
  }

  /// Transmits a signed, encrypted envelope over the mesh.
  bool sendMessage(C2Message message) {
    final channel = _wsChannel;
    if (!isConnected || channel == null) return false;

    try {
      channel.sink.add(jsonEncode(message.toEnvelopeJson()));
      return true;
    } catch (e) {
      debugPrint('[MESH_CLIENT] Send failed: $e');
      _handleDisconnect();
      return false;
    }
  }
}
