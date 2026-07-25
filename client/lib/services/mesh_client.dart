import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/c2_message.dart';

class NodePingResult {
  final String nodeId;
  final String httpUrl;
  final String wsUrl;
  final int latencyMs;
  final bool isOnline;

  NodePingResult({
    required this.nodeId,
    required this.httpUrl,
    required this.wsUrl,
    required this.latencyMs,
    required this.isOnline,
  });
}

class MeshClient {
  final String myOperatorId;
  final List<String> seedNodeUrls;

  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;

  String? activeNodeId;
  String? activeNodeUrl;
  int currentLatencyMs = 0;
  bool isConnected = false;

  final StreamController<C2Message> _incomingMessagesController =
      StreamController<C2Message>.broadcast();
  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();

  Stream<C2Message> get incomingMessages => _incomingMessagesController.stream;
  Stream<bool> get connectionState => _connectionStateController.stream;

  Timer? _pingProbeTimer;

  MeshClient({
    required this.myOperatorId,
    required this.seedNodeUrls,
  });

  /// Starts background ping prober and attaches to nearest node.
  void start() {
    _probeAndConnectNearestNode();
    _pingProbeTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _probeAndConnectNearestNode();
    });
  }

  void stop() {
    _pingProbeTimer?.cancel();
    _wsSubscription?.cancel();
    _wsChannel?.sink.close();
    isConnected = false;
    _connectionStateController.add(false);
  }

  /// Probes all candidate backend nodes concurrently to find lowest latency node.
  Future<void> _probeAndConnectNearestNode() async {
    List<NodePingResult> results = [];

    for (final baseUrl in seedNodeUrls) {
      try {
        final stopwatch = Stopwatch()..start();
        final response = await http
            .get(Uri.parse('$baseUrl/ping'))
            .timeout(const Duration(seconds: 3));
        stopwatch.stop();

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final uri = Uri.parse(baseUrl);
          final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
          final wsUri = uri.replace(
            scheme: wsScheme,
            path: uri.path.endsWith('/') ? '${uri.path}ws' : '${uri.path}/ws',
            queryParameters: {'operator_id': myOperatorId},
          );
          final wsUrl = wsUri.toString();
          results.add(NodePingResult(
            nodeId: data['node_id'] ?? 'unknown',
            httpUrl: baseUrl,
            wsUrl: wsUrl,
            latencyMs: stopwatch.elapsedMilliseconds,
            isOnline: true,
          ));
        }
      } catch (_) {
        // Node unreachable
      }
    }

    if (results.isEmpty) {
      isConnected = false;
      _connectionStateController.add(false);
      return;
    }

    // Sort nodes by lowest latency
    results.sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
    final bestNode = results.first;

    // Connect or switch if better node found
    if (!isConnected || activeNodeId != bestNode.nodeId) {
      _connectToNode(bestNode);
    } else {
      currentLatencyMs = bestNode.latencyMs;
    }
  }

  void _connectToNode(NodePingResult node) {
    try {
      _wsSubscription?.cancel();
      _wsChannel?.sink.close();

      final wsUri = Uri.parse(node.wsUrl);
      debugPrint('[MESH_CLIENT] Connecting WebSocket to: $wsUri');
      _wsChannel = WebSocketChannel.connect(wsUri);

      activeNodeId = node.nodeId;
      activeNodeUrl = node.httpUrl;
      currentLatencyMs = node.latencyMs;
      isConnected = true;
      _connectionStateController.add(true);

      _wsSubscription = _wsChannel!.stream.listen(
        (rawMessage) {
          try {
            debugPrint('[MESH_CLIENT] Received raw WebSocket message: $rawMessage');
            final Map<String, dynamic> jsonMap = jsonDecode(rawMessage);
            final msg = C2Message.fromEnvelopeJson(jsonMap, myOperatorId);
            _incomingMessagesController.add(msg);
          } catch (e) {
            debugPrint('[MESH_CLIENT ERROR] Parse failed: $e');
          }
        },
        onError: (err) {
          debugPrint('[MESH_CLIENT DISCONNECT] Error: $err');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('[MESH_CLIENT DISCONNECT] Connection closed');
          _handleDisconnect();
        },
      );
    } catch (e) {
      debugPrint('[MESH_CLIENT ERROR] Connect exception: $e');
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    isConnected = false;
    _connectionStateController.add(false);
    Future.delayed(const Duration(seconds: 3), _probeAndConnectNearestNode);
  }

  /// Transmits zero-knowledge message envelope over mesh.
  bool sendMessage(C2Message message) {
    debugPrint('[MESH_CLIENT OUTBOUND] sendMessage: type=${message.type}, id=${message.id}, recipient=${message.recipientId}, isConnected=$isConnected');
    if (!isConnected || _wsChannel == null) {
      return false;
    }
    try {
      final jsonPayload = jsonEncode(message.toEnvelopeJson());
      _wsChannel!.sink.add(jsonPayload);
      return true;
    } catch (e) {
      debugPrint('[MESH_CLIENT OUTBOUND ERROR] $e');
      return false;
    }
  }
}
