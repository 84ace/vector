import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/operator_profile.dart';
import '../../models/telemetry.dart';
import '../../services/ice_configuration.dart';
import '../../services/mesh_client.dart';
import '../../services/p2p_mesh_engine.dart';
import '../../services/transport_policy.dart';
import '../theme/c2_colors.dart';

/// What the comms stack is actually doing, in one screen.
///
/// Field failures in this app are almost never "the network is down" — they are
/// a seed refused for offering plaintext, a certificate the device will not
/// trust, a relay socket that authenticated and then dropped, or a call that
/// signalled fine and then found no media path. Those four look identical from
/// the outside: nothing arrives. The event log records them, but only the first
/// occurrence of each and interleaved with everything else, so answering "what
/// is wrong, right now" meant attaching a debugger to a device in the field.
///
/// Everything here is read from live client state. Nothing on this screen sends
/// anything, so it is safe to open while something is going wrong.
class NetworkDiagnosticsView extends StatefulWidget {
  final MeshClient meshClient;
  final P2PMeshEngine p2pMeshEngine;
  final OperatorProfile myProfile;
  final Telemetry? myTelemetry;
  final TransportPolicy transportPolicy;
  final String transportPolicyDefine;

  /// Shown in the P2P section rather than beside the relay policy, because it
  /// governs the direct links and nothing else.
  final P2PLinkPolicy p2pLinkPolicy;
  final bool hasPinnedRelayCa;
  final IceConfiguration ice;

  /// Paired contacts, so a P2P peer can be named rather than shown as a raw ID.
  final List<OperatorProfile> teamProfiles;

  const NetworkDiagnosticsView({
    super.key,
    required this.meshClient,
    required this.p2pMeshEngine,
    required this.myProfile,
    required this.myTelemetry,
    required this.transportPolicy,
    required this.transportPolicyDefine,
    this.p2pLinkPolicy = P2PLinkPolicy.plaintextAllowed,
    required this.hasPinnedRelayCa,
    required this.ice,
    required this.teamProfiles,
  });

  @override
  State<NetworkDiagnosticsView> createState() => _NetworkDiagnosticsViewState();
}

class _NetworkDiagnosticsViewState extends State<NetworkDiagnosticsView> {
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    // Polled rather than stream-driven: half of what is shown here (latency,
    // peer ages, probe timestamps) changes without any event firing, and a
    // second of staleness on a diagnostics screen costs nothing.
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mesh = widget.meshClient;

    return Scaffold(
      backgroundColor: C2Colors.slateBg,
      appBar: AppBar(
        backgroundColor: C2Colors.slateCard,
        title: const Row(
          children: [
            Icon(Icons.lan, color: Colors.cyanAccent, size: 20),
            SizedBox(width: 8),
            Text(
              'NETWORK DIAGNOSTICS',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all, color: Colors.cyanAccent),
            tooltip: 'Copy report',
            onPressed: _copyReport,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _headline(mesh),
          _section('RELAY LINK'),
          ..._relayRows(mesh),
          _section('SEED NODES (${mesh.seedDiagnostics.length})'),
          ..._seedRows(mesh),
          _section('DIRECT P2P LINKS'),
          ..._p2pRows(),
          _section('CALL MEDIA PATH'),
          ..._callRows(),
          _section('THIS DEVICE'),
          ..._deviceRows(),
          _section('PAIRED CONTACTS (${_contacts.length})'),
          ..._contactRows(),
        ],
      ),
    );
  }

  /// The one-line answer, in the language of the thing that is broken.
  Widget _headline(MeshClient mesh) {
    final (label, detail, colour) = switch (mesh) {
      _ when mesh.isConnected && mesh.isAuthenticated => (
          'RELAY CONNECTED',
          'Authenticated to ${mesh.activeNodeId} · ${mesh.currentLatencyMs}ms',
          C2Colors.emeraldAccent,
        ),
      _ when mesh.isConnected => (
          'RELAY CONNECTING',
          'Socket open, authentication not complete',
          C2Colors.warningAmber,
        ),
      _ => (
          'NO RELAY LINK',
          _noLinkExplanation(mesh),
          Colors.redAccent,
        ),
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colour),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: colour),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: colour,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: const TextStyle(color: Colors.white70, fontSize: 11, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Names the most likely cause rather than restating that nothing is
  /// connected, which the operator can already see.
  String _noLinkExplanation(MeshClient mesh) {
    final diagnostics = mesh.seedDiagnostics;
    if (diagnostics.isEmpty) return 'No seed nodes are configured in this build.';

    final refused = diagnostics.where((d) => d.outcome == SeedOutcome.refusedByPolicy).toList();
    final untrusted =
        diagnostics.where((d) => d.outcome == SeedOutcome.untrustedCertificate).toList();

    if (untrusted.isNotEmpty) {
      return '${untrusted.length} node(s) answered but presented a certificate this '
          'device does not trust. Pin the issuing CA with RELAY_CA_PEM_BASE64.';
    }
    if (refused.length == diagnostics.length) {
      return 'Every configured node was refused by the transport policy '
          '(${_policyLabel(widget.transportPolicy)}). Nothing was dialled.';
    }
    return 'Configured nodes did not answer. See the per-node detail below.';
  }

  List<Widget> _relayRows(MeshClient mesh) {
    return [
      _row('Policy', _policyLabel(widget.transportPolicy),
          note: 'TRANSPORT_POLICY="${widget.transportPolicyDefine}"'),
      _row('Pinned relay CA', widget.hasPinnedRelayCa ? 'YES' : 'NO — platform roots only'),
      _row('Active node', mesh.activeNodeId ?? '—'),
      _row('Active URL', mesh.activeNodeUrl ?? '—'),
      _row('Authenticated', mesh.isAuthenticated ? 'YES' : 'NO',
          colour: mesh.isAuthenticated ? C2Colors.emeraldAccent : Colors.redAccent),
      _row('Latency', mesh.isConnected ? '${mesh.currentLatencyMs}ms' : '—'),
      _row('Connected for', _since(mesh.connectedSince)),
      _row('Failed cycles', '${mesh.consecutiveFailures}',
          colour: mesh.consecutiveFailures > 0 ? C2Colors.warningAmber : null),
      if (mesh.lastDisconnectReason != null)
        _row(
          'Last drop',
          mesh.lastDisconnectReason!,
          note: mesh.lastDisconnectAt == null ? null : '${_age(mesh.lastDisconnectAt!)} ago',
          colour: C2Colors.warningAmber,
        ),
      _row(
        'Queued to send',
        mesh.outboxDepth == 0 ? 'NONE' : '${mesh.outboxDepth} envelope(s)',
        note: 'sealed and waiting for a link — re-sent on reconnect',
        colour: mesh.outboxDepth > 0 ? C2Colors.warningAmber : null,
      ),
      if (mesh.outboxDropped > 0)
        _row(
          'Discarded',
          '${mesh.outboxDropped} envelope(s)',
          note: 'outbox was full — these were never delivered',
          colour: Colors.redAccent,
        ),
    ];
  }

  List<Widget> _seedRows(MeshClient mesh) {
    final rows = <Widget>[];
    for (final seed in mesh.seedDiagnostics) {
      final isActive = seed.url == mesh.activeNodeUrl && mesh.isConnected;
      final (label, colour) = switch (seed.outcome) {
        SeedOutcome.notYetProbed => ('PROBING', Colors.white38),
        SeedOutcome.reachable => isActive
            ? ('IN USE', C2Colors.emeraldAccent)
            : ('AVAILABLE', C2Colors.emeraldAccent),
        SeedOutcome.refusedByPolicy => ('REFUSED', C2Colors.warningAmber),
        SeedOutcome.untrustedCertificate => ('UNTRUSTED CERT', Colors.redAccent),
        SeedOutcome.badResponse => ('BAD RESPONSE', Colors.redAccent),
        SeedOutcome.unreachable => ('NO ANSWER', Colors.redAccent),
      };

      rows.add(
        Container(
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: C2Colors.slateCard.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colour.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      seed.url,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(color: colour, fontSize: 9, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                seed.detail,
                style: const TextStyle(color: Colors.white54, fontSize: 10, height: 1.35),
              ),
              if (seed.nodeId != null || seed.checkedAt != null) ...[
                const SizedBox(height: 3),
                Text(
                  [
                    if (seed.nodeId != null) 'node ${seed.nodeId}',
                    if (seed.checkedAt != null) 'checked ${_age(seed.checkedAt!)} ago',
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white24, fontSize: 9),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return rows;
  }

  List<Widget> _p2pRows() {
    final peers = widget.p2pMeshEngine.activePeers.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    String nameFor(String operatorId) {
      for (final p in widget.teamProfiles) {
        if (p.id == operatorId || p.callsign.toUpperCase() == operatorId.toUpperCase()) {
          return p.callsign;
        }
      }
      return 'UNPAIRED';
    }

    final denied = widget.p2pLinkPolicy == P2PLinkPolicy.plaintextDenied;

    return [
      _row(
        'Link policy',
        denied ? 'DISABLED — P2P_PLAINTEXT=deny' : 'PLAINTEXT ON THE LAN',
        colour: denied ? C2Colors.warningAmber : null,
      ),
      if (denied)
        _note(
          'This build forms no direct device-to-device links. Everything routes '
          'through a relay node; on a network with no relay, nothing routes at '
          'all. Direct links have no encrypted variant to fall back to — there '
          'is no certificate infrastructure between handsets.',
        )
      else
        _note(
          'Direct links are plaintext WebSocket, authenticated in both '
          'directions by Ed25519 challenge/response and carrying only sealed '
          'envelopes. An observer on this subnet learns which operator IDs are '
          'linked, when, and message sizes — not their contents. This is not '
          'governed by TRANSPORT_POLICY; see SECURITY.md.',
        ),
      _row('Discovered peers', '${peers.length}'),
      // Worth stating outright: two devices on different carrier networks have
      // no P2P path at all, and an empty list here is expected rather than a
      // fault to chase.
      if (peers.isEmpty && !denied)
        _note(
          'No peers on this subnet. Direct links only form between devices on the '
          'same local network — two devices on different networks always route '
          'through the relay.',
        ),
      for (final peer in peers)
        _row(
          nameFor(peer.operatorId),
          '${peer.address}:${peer.port}',
          note: 'seen ${_age(peer.lastSeen)} ago · ${peer.operatorId}',
        ),
    ];
  }

  List<Widget> _callRows() {
    final ice = widget.ice;
    return [
      _row('STUN', ice.stunUrls.isEmpty ? 'DISABLED' : ice.stunUrls.join(', ')),
      _row(
        'TURN',
        ice.turnServers.isEmpty ? 'NOT CONFIGURED' : ice.turnServers.map((t) => t.url).join(', '),
        colour: ice.turnServers.isEmpty ? C2Colors.warningAmber : C2Colors.emeraldAccent,
      ),
      if (ice.turnServers.isEmpty)
        _note(
          'Without TURN, a call needs a direct path between the two devices. Two '
          'operators on different carrier networks, both behind NAT, will signal '
          'successfully and then fail to establish media — reported as CALL '
          'FAILED. This is deliberate: a TURN relay would see both endpoints\' '
          'addresses and the full stream. See SECURITY.md.',
        ),
      for (final advisory in ice.advisories) _note(advisory),
    ];
  }

  List<Widget> _deviceRows() {
    final tele = widget.myTelemetry;
    return [
      _row('Operator ID', widget.myProfile.id),
      _row('Callsign', widget.myProfile.callsign),
      _row(
        'Position',
        tele == null || (tele.latitude == 0.0 && tele.longitude == 0.0)
            ? 'NO FIX'
            : '${tele.latitude.toStringAsFixed(5)}, ${tele.longitude.toStringAsFixed(5)}',
        colour: tele == null ? C2Colors.warningAmber : null,
      ),
      if (tele != null) ...[
        _row('Fix accuracy', tele.accuracy > 0 ? '±${tele.accuracy.round()}m' : '—'),
        _row('Reported', '${_age(tele.timestamp)} ago',
            note: 'expected every ${tele.reportInterval.inSeconds}s'),
        _row('Link type', tele.networkType.name.toUpperCase()),
        _row('Battery', '${tele.batteryLevel}%${tele.isCharging ? ' (charging)' : ''}'),
      ],
    ];
  }

  // "Relay" is in every label on purpose: this policy has never governed the
  // direct links, and a label reading "plaintext refused everywhere" beside a
  // list of plaintext peer links said otherwise.
  List<OperatorProfile> get _contacts =>
      widget.teamProfiles.where((p) => p.id != widget.myProfile.id).toList();

  /// Operator IDs of every paired contact, so two devices can be compared.
  ///
  /// An operator ID is derived from the identity key, so it changes whenever the
  /// keystore entry does — a reinstall, or the bundle identifier moving. When it
  /// changes on one device the other still holds the old ID, and every envelope
  /// it sends is addressed to an operator that will never reconnect while every
  /// envelope it receives is rejected as an unknown sender. Nothing is logged on
  /// the relay for either case, so the symptom is silence in both directions.
  ///
  /// Reading these side by side is the fastest way to tell that apart from a
  /// transport fault, which is otherwise the same symptom.
  List<Widget> _contactRows() {
    if (_contacts.isEmpty) {
      return [
        _note(
          'No paired contacts. Nothing can be sent or received until pairing '
          'completes on both devices.',
        ),
      ];
    }

    return [
      for (final contact in _contacts)
        _row(
          contact.callsign,
          contact.id,
          note: contact.hasValidKeys
              ? 'keys present'
              : 'NO VERIFIABLE KEYS — re-pair this contact',
          colour: contact.hasValidKeys ? null : Colors.redAccent,
        ),
      _note(
        'Compare these against the other device\'s own operator ID under THIS '
        'DEVICE. If they do not match, the pairing is stale — reinstalling or '
        'changing the bundle identifier regenerates the identity key, and both '
        'operators must re-pair.',
      ),
    ];
  }

  String _policyLabel(TransportPolicy policy) => switch (policy) {
        TransportPolicy.tlsOnly => 'TLS ONLY — no plaintext relay, anywhere',
        TransportPolicy.privateNetworkPlaintext => 'PRIVATE — plaintext relay on the LAN only',
        TransportPolicy.allowAllPlaintext => 'ANY — plaintext relay permitted anywhere',
      };

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
        child: Text(
          title,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
      );

  Widget _row(String label, String value, {String? note, Color? colour}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  value,
                  style: TextStyle(
                    color: colour ?? Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (note != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    note,
                    style: const TextStyle(color: Colors.white24, fontSize: 9, height: 1.3),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _note(String text) => Container(
        margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(6),
          border: Border(left: BorderSide(color: C2Colors.warningAmber, width: 2)),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white60, fontSize: 10, height: 1.45),
        ),
      );

  static String _since(DateTime? when) {
    if (when == null) return '—';
    return _age(when);
  }

  static String _age(DateTime when) {
    final d = DateTime.now().difference(when);
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    if (d.inHours < 24) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inDays}d';
  }

  /// Copies the whole state as text.
  ///
  /// Reading numbers off a phone screen over a radio is how detail gets lost;
  /// this makes a report that can be pasted into an issue.
  Future<void> _copyReport() async {
    final mesh = widget.meshClient;
    final lines = <String>[
      'VECTOR NETWORK DIAGNOSTICS',
      'operator: ${widget.myProfile.callsign} (${widget.myProfile.id})',
      '',
      'RELAY',
      '  policy: ${widget.transportPolicyDefine} (${_policyLabel(widget.transportPolicy)})',
      '  pinned CA: ${widget.hasPinnedRelayCa}',
      '  connected: ${mesh.isConnected}  authenticated: ${mesh.isAuthenticated}',
      '  node: ${mesh.activeNodeId ?? "-"} @ ${mesh.activeNodeUrl ?? "-"}',
      '  latency: ${mesh.currentLatencyMs}ms  failed cycles: ${mesh.consecutiveFailures}',
      '  connected for: ${_since(mesh.connectedSince)}',
      '  outbox: ${mesh.outboxDepth} queued, ${mesh.outboxDropped} discarded',
      if (mesh.lastDisconnectReason != null)
        '  last drop: ${mesh.lastDisconnectReason} (${_age(mesh.lastDisconnectAt!)} ago)',
      '',
      'SEEDS',
      for (final s in mesh.seedDiagnostics)
        '  ${s.url} → ${s.outcome.name}: ${s.detail}',
      '',
      'P2P',
      '  discovered: ${widget.p2pMeshEngine.activePeers.length}',
      for (final p in widget.p2pMeshEngine.activePeers.values)
        '  ${p.operatorId} @ ${p.address}:${p.port} (seen ${_age(p.lastSeen)} ago)',
      '',
      'CALL PATH',
      '  stun: ${widget.ice.stunUrls.isEmpty ? "disabled" : widget.ice.stunUrls.join(", ")}',
      '  turn: ${widget.ice.turnServers.isEmpty ? "not configured" : widget.ice.turnServers.map((t) => t.url).join(", ")}',
      '',
      'PAIRED CONTACTS',
      if (_contacts.isEmpty) '  none',
      for (final c in _contacts)
        '  ${c.callsign}: ${c.id}${c.hasValidKeys ? "" : "  [NO VALID KEYS]"}',
    ];

    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: C2Colors.slateCard,
        duration: Duration(seconds: 2),
        content: Text(
          'DIAGNOSTIC REPORT COPIED',
          style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
