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

/// What happened the last time a seed node was probed.
///
/// These are deliberately distinct outcomes rather than a bool: "refused for
/// offering plaintext", "answered but with an untrusted certificate" and "did
/// not answer" call for three completely different fixes, and collapsing them
/// into "offline" is what made a misconfigured deployment indistinguishable
/// from an outage.
enum SeedOutcome {
  notYetProbed,
  reachable,
  refusedByPolicy,
  untrustedCertificate,
  badResponse,
  unreachable,
}

class SeedDiagnostic {
  final String url;
  final SeedOutcome outcome;
  final String detail;
  final int? latencyMs;
  final String? nodeId;
  final DateTime? checkedAt;

  const SeedDiagnostic({
    required this.url,
    required this.outcome,
    required this.detail,
    this.latencyMs,
    this.nodeId,
    this.checkedAt,
  });
}

class MeshClient {
  static const _probeInterval = Duration(seconds: 30);
  static const _probeTimeout = Duration(seconds: 3);
  static const _authTimeout = Duration(seconds: 10);
  static const _maxBackoff = Duration(minutes: 2);

  /// How often to ping the node. Comfortably inside the shortest carrier NAT
  /// UDP/TCP idle timeouts seen in practice (30-60s), and well inside the node's
  /// own 60s pong deadline.
  static const _pingInterval = Duration(seconds: 20);

  /// Envelopes worth holding onto when there is no transport. Bounded, because
  /// this is a field device and an operator out of range for an hour must not
  /// come back to an unbounded backlog.
  static const _maxOutbox = 200;

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

  /// What the last probe of each seed actually did.
  ///
  /// The event log only records the first refusal of each seed, which is right
  /// for a log but useless for the question an operator asks in the field —
  /// "which node am I on, and what is wrong with the others, right now". This is
  /// the live answer, read by the diagnostics screen.
  final Map<String, SeedDiagnostic> _seedDiagnostics = {};

  /// Why the socket last went away, if it has.
  String? lastDisconnectReason;
  DateTime? lastDisconnectAt;
  DateTime? connectedSince;

  /// Envelopes sealed but not yet handed to a transport. See [sendMessage].
  final List<C2Message> _outbox = [];
  int _outboxDropped = 0;

  /// How many sealed envelopes are waiting for a link, and how many have been
  /// discarded for want of one. Both are shown on the diagnostics screen: a
  /// backlog that never drains is the difference between "sent" and "delivered".
  int get outboxDepth => _outbox.length;
  int get outboxDropped => _outboxDropped;

  /// Live per-seed status, in the order the seeds were configured.
  List<SeedDiagnostic> get seedDiagnostics => [
        for (final url in seedNodeUrls)
          _seedDiagnostics[url] ??
              SeedDiagnostic(
                url: url,
                outcome: SeedOutcome.notYetProbed,
                detail: 'no probe completed yet',
                checkedAt: null,
              ),
      ];

  bool get isAuthenticated => _authenticated;

  /// Consecutive failed probe/connect cycles, which drives the backoff.
  int get consecutiveFailures => _consecutiveFailures;

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
    connectedSince = connected ? DateTime.now() : null;
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
        _recordSeed(baseUrl, SeedOutcome.refusedByPolicy,
            transportRefusalReason(baseUrl, transportPolicy));
        return null;
      }

      final stopwatch = Stopwatch()..start();
      final response =
          await _probe.get(uri.replace(path: _joinPath(uri.path, 'ping'))).timeout(_probeTimeout);
      stopwatch.stop();

      if (response.statusCode != 200) {
        _recordSeed(baseUrl, SeedOutcome.badResponse,
            'GET /ping answered HTTP ${response.statusCode}');
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      final wsUri = uri.replace(
        scheme: uri.scheme == 'https' ? 'wss' : 'ws',
        path: _joinPath(uri.path, 'ws'),
      );

      final nodeId = data['node_id'] as String? ?? 'unknown';
      _recordSeed(
        baseUrl,
        SeedOutcome.reachable,
        'answered /ping in ${stopwatch.elapsedMilliseconds}ms',
        latencyMs: stopwatch.elapsedMilliseconds,
        nodeId: nodeId,
      );

      return NodePingResult(
        nodeId: nodeId,
        httpUrl: baseUrl,
        wsUrl: wsUri.toString(),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on HandshakeException catch (e) {
      // A rejected certificate is not an unreachable node, and conflating the
      // two is how a TLS misconfiguration presents as hours of silent outage:
      // the node is up, answering, and simply never selected. Say so instead.
      _reportTlsFailure(baseUrl, e);
      _recordSeed(baseUrl, SeedOutcome.untrustedCertificate, _tlsDetail(e));
      return null;
    } on TlsException catch (e) {
      _reportTlsFailure(baseUrl, e);
      _recordSeed(baseUrl, SeedOutcome.untrustedCertificate, _tlsDetail(e));
      return null;
    } on TimeoutException {
      _recordSeed(baseUrl, SeedOutcome.unreachable,
          'no answer within ${_probeTimeout.inSeconds}s');
      return null;
    } catch (e) {
      _recordSeed(baseUrl, SeedOutcome.unreachable, _shortError(e));
      return null; // Node unreachable.
    }
  }

  void _recordSeed(
    String url,
    SeedOutcome outcome,
    String detail, {
    int? latencyMs,
    String? nodeId,
  }) {
    _seedDiagnostics[url] = SeedDiagnostic(
      url: url,
      outcome: outcome,
      detail: detail,
      latencyMs: latencyMs,
      nodeId: nodeId,
      checkedAt: DateTime.now(),
    );
  }

  static String _tlsDetail(Object error) {
    final message = error is TlsException ? error.message : error.toString();
    return message.isEmpty ? 'certificate not trusted' : message;
  }

  /// Error text an operator can act on, without a Dart stack trace in it.
  static String _shortError(Object error) {
    var text = error.toString();
    if (text.startsWith('SocketException: ')) {
      text = text.substring('SocketException: '.length);
    }
    final comma = text.indexOf(', ');
    if (comma > 0) text = text.substring(0, comma);
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
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
        // Without this the client cannot tell a live socket from a dead one.
        //
        // The node pings every 54s and `dart:io` answers automatically, so the
        // server notices when we vanish — but nothing ran in this direction. A
        // carrier NAT dropping an idle flow leaves the socket half-open here:
        // writes succeed into a buffer that goes nowhere, `isConnected` stays
        // true, and the probe loop below therefore declines to reconnect because
        // /ping — a separate HTTP request over the pooled client — keeps
        // answering perfectly. The relay logged `close 1006 unexpected EOF`
        // while this end believed it was connected, and every envelope written
        // in between was lost with the sender's UI showing it as sent.
        //
        // With a ping interval set, `dart:io` closes the socket when a pong does
        // not come back, which lands in _handleDisconnect and reconnects.
        pingInterval: _pingInterval,
      );
      await channel.ready.timeout(_authTimeout);
      _wsChannel = channel;

      // A WebSocketChannel stream is single-subscription, so the handshake runs
      // through the same listener the envelopes will use, gated on _authenticated.
      _wsSubscription = channel.stream.listen(
        _handleFrame,
        onError: (Object err) {
          debugPrint('[MESH_CLIENT] Socket error: $err');
          _handleDisconnect(err);
        },
        onDone: () => _handleDisconnect(),
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

      // Only now: the node routes nothing for an unauthenticated session, so
      // flushing any earlier would discard the backlog into a socket that drops
      // it on the floor.
      _flushOutbox();
    } catch (e) {
      debugPrint('[MESH_CLIENT] Connect/auth failed for ${node.nodeId}: $e');
      await _wsChannel?.sink.close();
      _wsChannel = null;
      _handleDisconnect(e);
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

  void _handleDisconnect([Object? error]) {
    if (isConnected || error != null) {
      lastDisconnectReason = error == null ? 'socket closed' : _shortError(error);
      lastDisconnectAt = DateTime.now();
    }

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
  ///
  /// With [queueIfUnsent], an envelope that cannot go out now is held and
  /// re-sent when a link comes back. Use it for anything an operator would
  /// consider sent — chat, call signalling, a distress beacon. Do not use it for
  /// telemetry: a position report that arrives ten minutes late is worse than
  /// one that never arrives, because it will be read as current.
  bool sendMessage(C2Message message, {bool queueIfUnsent = false}) {
    final channel = _wsChannel;
    if (!isConnected || channel == null) {
      if (queueIfUnsent) _enqueue(message);
      return false;
    }

    try {
      channel.sink.add(jsonEncode(message.toEnvelopeJson()));
      return true;
    } catch (e) {
      debugPrint('[MESH_CLIENT] Send failed: $e');
      if (queueIfUnsent) _enqueue(message);
      _handleDisconnect(e);
      return false;
    }
  }

  /// Holds a sealed envelope for the next link.
  ///
  /// The **sealed** envelope, deliberately, and not the plaintext to re-seal
  /// later: sealing already advanced the ratchet and consumed a message key, so
  /// re-sealing would burn a second one and hand the far end a gap.
  void _enqueue(C2Message message) {
    if (_outbox.any((m) => m.id == message.id)) return;
    if (_outbox.length >= _maxOutbox) {
      // Oldest first: in a comms backlog the newest traffic is the useful part.
      final dropped = _outbox.removeAt(0);
      debugPrint('[MESH_CLIENT] Outbox full, dropped ${dropped.id}');
      _outboxDropped++;
    }
    _outbox.add(message);
  }

  /// Re-sends everything held while there was no link.
  ///
  /// Called on connect rather than on a timer, because "a link exists" is the
  /// only event that changes the answer.
  void _flushOutbox() {
    if (_outbox.isEmpty) return;
    final pending = List<C2Message>.of(_outbox);
    _outbox.clear();

    var sent = 0;
    for (final message in pending) {
      // Re-queues on failure, so a socket that dies mid-flush keeps the tail.
      if (sendMessage(message, queueIfUnsent: true)) sent++;
    }
    debugPrint('[MESH_CLIENT] Flushed $sent/${pending.length} queued envelopes');
  }
}
