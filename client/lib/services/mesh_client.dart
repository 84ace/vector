import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/io_client.dart' as http_io;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/operator_identity.dart';
import '../models/c2_message.dart';
import 'transport_policy.dart';

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

  /// How much this client trusts an unencrypted transport.
  ///
  /// Envelope bodies are end-to-end encrypted either way, but plaintext
  /// transport exposes routing metadata — who is talking to whom, and when —
  /// which for this application is itself sensitive.
  ///
  /// The default refuses plaintext to a routable host while still permitting it
  /// on the LAN, because an isolated-network deployment has nowhere to get a
  /// certificate from and that is the setup this app is built for. It is not a
  /// flag anyone has to remember to turn on: the case that leaks metadata to
  /// the internet is refused out of the box.
  final TransportPolicy transportPolicy;

  /// Additional trust anchor for relay certificates, or null for platform roots
  /// only. See [relayTrustContext] for why an isolated deployment needs one.
  final SecurityContext? trustContext;

  /// One client for both the probe and the WebSocket upgrade, so they agree on
  /// which certificates to trust and share a connection pool.
  HttpClient? _httpClient;
  http_io.IOClient? _probeClient;

  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;

  String? activeNodeId;
  String? activeNodeUrl;
  int currentLatencyMs = 0;
  bool isConnected = false;

  final _incomingMessagesController = StreamController<C2Message>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  final _transportRefusalController = StreamController<String>.broadcast();

  /// Seed nodes skipped for offering an unacceptable transport. A silently
  /// dropped seed looks identical to an unreachable one, which is how a
  /// misconfigured deployment reads as "the node is down" for hours.
  final Set<String> _reportedRefusals = {};

  Stream<C2Message> get incomingMessages => _incomingMessagesController.stream;
  Stream<bool> get connectionState => _connectionStateController.stream;
  Stream<String> get transportRefusals => _transportRefusalController.stream;

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
    this.transportPolicy = TransportPolicy.privateNetworkPlaintext,
    this.trustContext,
  });

  HttpClient get _client {
    final existing = _httpClient;
    if (existing != null) return existing;
    final created = HttpClient(context: trustContext)
      ..connectionTimeout = _probeTimeout;
    _httpClient = created;
    return created;
  }

  /// Wraps [_client] without owning it — closing this would close the client
  /// the WebSocket upgrade also uses.
  http_io.IOClient get _probe => _probeClient ??= http_io.IOClient(_client);

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
    await _transportRefusalController.close();
    _probeClient = null;
    _httpClient?.close(force: true);
    _httpClient = null;
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
      if (!isTransportAllowed(baseUrl, transportPolicy)) {
        _reportTransportRefusal(baseUrl);
        return null;
      }

      final stopwatch = Stopwatch()..start();
      final response =
          await _probe.get(uri.replace(path: _joinPath(uri.path, 'ping'))).timeout(_probeTimeout);
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
    } on HandshakeException catch (e) {
      // A rejected certificate is not an unreachable node, and conflating the
      // two is how a TLS misconfiguration presents as hours of silent outage:
      // the node is up, answering, and simply never selected. Say so instead.
      _reportTlsFailure(baseUrl, e);
      return null;
    } on TlsException catch (e) {
      _reportTlsFailure(baseUrl, e);
      return null;
    } catch (_) {
      return null; // Node unreachable.
    }
  }

  /// Announces a refused seed once. The probe timer fires every 30s, so
  /// reporting on every tick would bury the operator's event log.
  void _reportTransportRefusal(String baseUrl) {
    final reason = transportRefusalReason(baseUrl, transportPolicy);
    debugPrint('[MESH_CLIENT] Skipping $baseUrl: $reason');
    _announceOnce(baseUrl, reason);
  }

  void _reportTlsFailure(String baseUrl, Object error) {
    debugPrint('[MESH_CLIENT] TLS failure for $baseUrl: $error');
    _announceOnce(
      baseUrl,
      'the node presented a certificate this device does not trust. Use a '
          'publicly-trusted certificate, or pin the issuing CA with '
          '--dart-define=RELAY_CA_PEM_BASE64=... (see DEPLOYMENT.md)',
    );
  }

  void _announceOnce(String baseUrl, String reason) {
    if (!_reportedRefusals.add(baseUrl)) return;
    if (!_transportRefusalController.isClosed) {
      _transportRefusalController.add('$baseUrl — $reason');
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

    // This completer can be failed before anything awaits it: a host that
    // accepts TCP and answers /ping but refuses the /ws upgrade — a captive
    // portal, or a reverse proxy that forwards only HTTP — throws out of
    // `channel.ready` below, and the catch block then errors the completer.
    // Register a sink for that error up front, or it surfaces as an unhandled
    // async exception instead of a reconnect.
    unawaited(auth.future.catchError((Object _) {}));

    try {
      // IOWebSocketChannel rather than WebSocketChannel.connect so the upgrade
      // runs through the same HttpClient as the probe. Otherwise a pinned CA
      // would satisfy /ping and then be unknown to the wss:// handshake.
      final channel = IOWebSocketChannel.connect(
        Uri.parse(node.wsUrl),
        customClient: _client,
      );
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
