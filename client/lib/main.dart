import 'dart:async';
import 'dart:convert';
import 'dart:io' show SecurityContext;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crypto/e2ee_engine.dart';
import 'crypto/group_engine.dart';
import 'crypto/operator_identity.dart';
import 'models/c2_event_log.dart';
import 'models/c2_message.dart';
import 'models/operator_profile.dart';
import 'models/telemetry.dart';
import 'services/mesh_client.dart';
import 'services/p2p_mesh_engine.dart';
import 'services/ptt_audio_service.dart';
import 'services/secure_channel.dart';
import 'services/team_key_distributor.dart';
import 'services/telemetry_service.dart';
import 'services/transport_policy.dart';
import 'services/webrtc_call_service.dart';
import 'services/ptt_recorder.dart';
import 'ui/chat/audience_selector.dart';
import 'ui/chat/call_screen.dart';
import 'ui/comms/conversation_list.dart';
import 'ui/comms/conversation_view.dart';
import 'ui/map/tactical_map_view.dart';
import 'ui/onboarding/onboarding_view.dart';
import 'ui/onboarding/qr_pairing_view.dart';
import 'ui/settings/settings_view.dart';
import 'ui/theme/c2_colors.dart';

void main() {
  runApp(const VectorC2App());
}

class VectorC2App extends StatelessWidget {
  const VectorC2App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vector C2 Tactical Platform',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        primaryColor: Colors.cyanAccent,
        colorScheme: const ColorScheme.dark(
          primary: Colors.cyanAccent,
          secondary: C2Colors.emeraldAccent,
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const MainShellView(),
    );
  }
}

/// Primary destinations, in bottom-navigation order.
///
/// Named rather than indexed: the shell reads and writes the current
/// destination from a dozen places, and bare integers made every reordering a
/// chance to silently wire a button to the wrong screen.
enum AppTab { map, squad, settings }

class MainShellView extends StatefulWidget {
  const MainShellView({super.key});

  @override
  State<MainShellView> createState() => _MainShellViewState();
}

class _MainShellViewState extends State<MainShellView> {
  AppTab _currentTab = AppTab.map;

  bool _isLoading = true;
  bool _myProfileInitialized = false;
  late OperatorProfile _myProfile;
  final List<OperatorProfile> _teamProfiles = [];
  final List<C2Message> _globalMessages = [];
  final List<C2EventLog> _eventLogs = [];
  final Set<String> _consumedPairingTokens = {};
  final Set<String> _activePairingDialogs = {};

  /// Operators we have sent a pairing request to and are awaiting an ack from.
  ///
  /// An unsolicited PAIR_ACK is refused. Without this gate, one forged ack was
  /// enough to be added to a device's contact list with attacker-chosen keys.
  ///
  /// Persisted, because a pairing request is routinely emitted before any
  /// transport to the peer exists: scanning a code takes an instant, while
  /// discovering and authenticating a direct link takes seconds. The request is
  /// retried whenever a route to that operator appears.
  final Set<String> _pendingPairRequests = {};
  Timer? _pairRetryTimer;
  int _pairRetriesRemaining = 0;

  /// Unread counts per audience key, cleared when its conversation is opened.
  final Map<String, int> _unreadByConversation = {};

  /// The conversation currently on screen, so its arrivals are not counted
  /// as unread and its notifications are suppressed.
  String? _openConversationKey;

  bool _callRouteOpen = false;
  Timer? _callTimer;
  int _callSeconds = 0;
  final ValueNotifier<int> _callTicker = ValueNotifier(0);
  final ValueNotifier<int> _callRouteRevision = ValueNotifier(0);

  static String _conversationKey(Audience a) =>
      a.isDirect ? 'direct:${a.peer?.id}' : a.kind.name;

  /// Set when the device cannot provide secure key storage. The app stops here
  /// rather than starting up with keys it could not protect.
  SecureStorageUnavailable? _storageFailure;
  RelayTrustAnchorInvalid? _trustAnchorFailure;
  OperatorProfile? _activeCallPeer;

  late OperatorIdentity _identity;
  late E2EEEngine _pairwiseEngine;
  late TeamGroupEngine _teamEngine;
  late SecureChannel _channel;
  late MeshClient _meshClient;
  late P2PMeshEngine _p2pMeshEngine;
  late TelemetryService _telemetryService;
  late PttRecorder _pttRecorder;
  late WebRtcCallService _callService;
  late TeamKeyDistributor _teamKeyDistributor;

  final List<StreamSubscription> _subscriptions = [];

  bool _isMeshConnected = false;
  String _activeNodeId = 'OFFLINE';
  Telemetry? _myTelemetry;
  Map<String, Telemetry> _teamTelemetry = {};
  String? _activeSosOperatorCallsign;

  static const String _cloudNodeEnv =
      String.fromEnvironment('CLOUD_MESH_NODE_URL', defaultValue: '');
  static const String _nasNodeEnv =
      String.fromEnvironment('NAS_MESH_NODE_URL', defaultValue: '');
  static const String _localNodeEnv =
      String.fromEnvironment('LOCAL_MESH_NODE_URL', defaultValue: 'http://127.0.0.1:8080');
  static const String _fieldRouterEnv =
      String.fromEnvironment('FIELD_ROUTER_NODE_URL', defaultValue: '');

  /// Transport strictness, baked in at build time alongside the seed URLs.
  ///
  /// Configured the same way as everything else here rather than as a runtime
  /// toggle: the previous `require_tls` preference defaulted to false and no
  /// screen ever wrote it, so the check it guarded could never fire.
  static const String _transportPolicyEnv =
      String.fromEnvironment('TRANSPORT_POLICY', defaultValue: 'private');

  /// Base64 PEM of a CA to trust for relay certificates, on top of the platform
  /// roots. Needed for wss:// on an isolated network, which has no way to obtain
  /// a publicly-trusted certificate. See DEPLOYMENT.md.
  static const String _relayCaPemEnv =
      String.fromEnvironment('RELAY_CA_PEM_BASE64', defaultValue: '');

  /// Seed nodes come from --dart-define at build time. Nothing is hardcoded to a
  /// specific deployment any more: a build with no defines only tries localhost.
  List<String> get candidateMeshNodes => [
        _cloudNodeEnv,
        _nasNodeEnv,
        _localNodeEnv,
        _fieldRouterEnv,
      ].where((url) => url.isNotEmpty).toList();

  /// Maps the build-time define onto a policy, defaulting to the safe end.
  ///
  /// An unrecognised value falls back to the default rather than the permissive
  /// end, so a typo in a deploy script cannot be what turns metadata protection
  /// off. Returns null when the value was not understood, so the caller can say
  /// so in the event log.
  static TransportPolicy? _parseTransportPolicy(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'private':
        return TransportPolicy.privateNetworkPlaintext;
      case 'tls-only':
      case 'tls_only':
        return TransportPolicy.tlsOnly;
      case 'any':
      case 'insecure':
        return TransportPolicy.allowAllPlaintext;
      default:
        return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _loadPersistedState();
  }

  OperatorProfile? _findContact(String operatorId) {
    for (final p in _teamProfiles) {
      if (p.id == operatorId) return p;
    }
    return null;
  }

  String _callsignFor(String operatorId) =>
      _findContact(operatorId)?.callsign ?? operatorId;

  Future<void> _loadPersistedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final profileJson = prefs.getString('c2_my_profile');

      final consumedTokensJson = prefs.getString('c2_consumed_pairing_tokens');
      if (consumedTokensJson != null) {
        _consumedPairingTokens.addAll(
          (jsonDecode(consumedTokensJson) as List<dynamic>).cast<String>(),
        );
      }

      final pendingJson = prefs.getString('c2_pending_pair_requests');
      if (pendingJson != null) {
        _pendingPairRequests.addAll(
          (jsonDecode(pendingJson) as List<dynamic>).cast<String>(),
        );
      }

      final logsJson = prefs.getString('c2_event_logs');
      if (logsJson != null) {
        _eventLogs
          ..clear()
          ..addAll((jsonDecode(logsJson) as List<dynamic>)
              .map((l) => C2EventLog.fromJson(l as Map<String, dynamic>)));
      }

      if (profileJson != null) {
        final profile = OperatorProfile.fromJson(jsonDecode(profileJson) as Map<String, dynamic>);
        await _initializeServices(profile);
        return;
      }
    } catch (e) {
      debugPrint('[STARTUP] Failed to restore state: $e');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _initializeServices(OperatorProfile profile) async {
    try {
      await [Permission.microphone, Permission.location, Permission.camera].request();
    } catch (_) {}

    // Identity keys live in the Keychain / Android Keystore, not in
    // SharedPreferences, and the operator ID is derived from the signing key so
    // it cannot be claimed by anyone else.
    //
    // If the keystore is unreachable this is fatal: the alternative is holding
    // private keys somewhere unprotected, which would leave the app looking
    // like it worked while voiding the guarantee everything else depends on.
    try {
      _identity = await OperatorIdentity.loadOrCreate();
      _teamEngine = await TeamGroupEngine.loadOrCreate(
        groupId: 'grp-strike-team-alpha',
        groupName: 'STRIKE TEAM ALPHA',
      );
    } on SecureStorageUnavailable catch (e) {
      debugPrint('[STARTUP] Secure storage unavailable: ${e.detail}');
      if (mounted) {
        setState(() {
          _storageFailure = e;
          _isLoading = false;
        });
      }
      return;
    }
    _pairwiseEngine = E2EEEngine(identity: _identity);

    _myProfile = profile.copyWith(
      id: _identity.operatorId,
      signPublicKey: _identity.signPublicKey,
      kexPublicKey: _identity.kexPublicKey,
    );

    _channel = SecureChannel(
      identity: _identity,
      pairwise: _pairwiseEngine,
      team: _teamEngine,
      lookupContact: _findContact,
    );

    final prefs = await SharedPreferences.getInstance();

    _teamProfiles
      ..clear()
      ..add(_myProfile);

    final contactsJson = prefs.getString('c2_contacts');
    if (contactsJson != null) {
      var droppedLegacy = 0;
      for (final contactMap in jsonDecode(contactsJson) as List<dynamic>) {
        final contact = OperatorProfile.fromJson(contactMap as Map<String, dynamic>);
        // Contacts saved before the key rework carry no usable keys. Keeping
        // them would mean showing unverifiable operators as trusted.
        if (contact.hasValidKeys) {
          _teamProfiles.add(contact);
        } else {
          droppedLegacy++;
        }
      }
      if (droppedLegacy > 0) {
        await _persistContacts();
        _addEventLog(
          'CONTACTS REQUIRE RE-PAIRING',
          '$droppedLegacy contact(s) from a previous version were removed: they '
              'predate identity keys and cannot be verified. Re-pair to restore comms.',
          EventSeverity.security,
        );
      }
    }

    final chatHistoryJson = prefs.getString('c2_chat_history');
    if (chatHistoryJson != null) {
      _globalMessages.clear();
      for (final m in jsonDecode(chatHistoryJson) as List<dynamic>) {
        try {
          _globalMessages.add(
            C2Message.fromEnvelopeJson(m as Map<String, dynamic>, _myProfile.id),
          );
        } catch (_) {
          // Skip records written by an incompatible build.
        }
      }
    }

    await prefs.setString('c2_my_profile', jsonEncode(_myProfile.toJson()));

    // A CA that will not parse is fatal for the same reason a missing keystore
    // is: continuing on platform roots alone would leave every pinned node
    // looking unreachable, with nothing on screen saying why.
    final SecurityContext? relayTrust;
    try {
      relayTrust = relayTrustContext(_relayCaPemEnv);
    } on RelayTrustAnchorInvalid catch (e) {
      debugPrint('[STARTUP] Relay CA invalid: ${e.detail}');
      if (mounted) {
        setState(() {
          _trustAnchorFailure = e;
          _isLoading = false;
        });
      }
      return;
    }

    _meshClient = MeshClient(
      identity: _identity,
      seedNodeUrls: candidateMeshNodes,
      transportPolicy: _parseTransportPolicy(_transportPolicyEnv) ??
          TransportPolicy.privateNetworkPlaintext,
      trustContext: relayTrust,
    );

    if (_parseTransportPolicy(_transportPolicyEnv) == null) {
      _addEventLog(
        'UNKNOWN TRANSPORT_POLICY VALUE',
        'Build defines TRANSPORT_POLICY="$_transportPolicyEnv", which is not one '
            'of private / tls-only / any. Falling back to "private": plaintext is '
            'permitted on the local network only.',
        EventSeverity.warning,
      );
    }

    _p2pMeshEngine = P2PMeshEngine(
      identity: _identity,
      p2pPort: 9090,
      isPairedContact: (id) => _findContact(id) != null,
      announceEnabled: prefs.getBool('p2p_announce') ?? true,
    );

    _telemetryService = TelemetryService(
      channel: _channel,
      meshClient: _meshClient,
      p2pMeshEngine: _p2pMeshEngine,
    );

    _pttRecorder = PttRecorder(
      channel: _channel,
      meshClient: _meshClient,
      p2pMeshEngine: _p2pMeshEngine,
      myProfile: _myProfile,
    );
    await _pttRecorder.loadSettings();

    _callService = WebRtcCallService(
      channel: _channel,
      meshClient: _meshClient,
      p2pMeshEngine: _p2pMeshEngine,
    );

    _teamKeyDistributor = TeamKeyDistributor(
      sendRekey: _sendTeamKeyTo,
      lookupContact: _findContact,
      currentEpoch: () => _teamEngine.epoch,
      persist: _persistPendingRekeys,
    );

    // Obligations from a previous run resume now. A rotation that happened
    // while a squad member was offline outlives the process that performed it.
    final pendingRekeysJson = prefs.getString('c2_pending_rekeys');
    if (pendingRekeysJson != null) {
      try {
        _teamKeyDistributor.restore(
          (jsonDecode(pendingRekeysJson) as List<dynamic>).cast<String>(),
        );
      } catch (_) {
        // Written by an incompatible build; the rotation will be re-driven by
        // the next unpair rather than resumed.
      }
    }

    // A deployment that turned TURN on, or left public STUN on, should be able
    // to see that from inside the app rather than by reading the build script.
    for (final advisory in _callService.ice.advisories) {
      _addEventLog('CALL PATH ADVISORY', advisory, EventSeverity.warning);
    }

    await PttAudioService.initializeGlobalListener(
      meshClient: _meshClient,
      p2pMeshEngine: _p2pMeshEngine,
      channel: _channel,
      resolveCallsign: _callsignFor,
    );

    PttAudioService.onClipReceived = (clip, autoPlay) {
      if (!mounted) return;
      _addEventLog(
        autoPlay ? 'LIVE PTT PLAYED' : 'VOICE CLIP BUFFERED',
        'Voice clip (${clip.durationSecs}s) received from ${clip.senderCallsign}',
        EventSeverity.info,
      );
      _showInAppNotification(
        title: autoPlay
            ? '📻 LIVE PTT FROM ${clip.senderCallsign.toUpperCase()}'
            : '🎙️ VOICE CLIP FROM ${clip.senderCallsign.toUpperCase()}',
        message: autoPlay
            ? 'Playing live PTT transmission (${clip.durationSecs}s)...'
            : 'Buffered ${clip.durationSecs}s voice clip. Tap to listen.',
        color: autoPlay ? C2Colors.emeraldAccent : Colors.amberAccent,
        onTap: () {
          final sender = _findContact(clip.senderId);
          if (sender != null) _openConversation(Audience.direct(sender));
        },
      );
    };

    _subscriptions.addAll([
      _meshClient.connectionState.listen((connected) {
        if (!mounted) return;
        setState(() {
          _isMeshConnected = connected;
          _activeNodeId = connected ? (_meshClient.activeNodeId ?? 'mesh-node') : 'OFFLINE';
        });
        if (connected) {
          _retryPendingPairRequests();
          _teamKeyDistributor.onRouteAvailable();
        }
      }),
      _meshClient.incomingMessages.listen(_processIncomingMessage),
      // A seed refused for offering plaintext is otherwise indistinguishable
      // from one that is simply down, which turns a misconfigured deployment
      // into an unexplained outage.
      _meshClient.transportRefusals.listen((detail) {
        if (!mounted) return;
        _addEventLog('NODE SKIPPED: INSECURE TRANSPORT', detail, EventSeverity.security);
      }),
      _p2pMeshEngine.incomingP2PMessages.listen(_processIncomingMessage),
      _p2pMeshEngine.discoveredPeers.listen((peers) {
        if (!mounted) return;
        setState(() {
          if (!_isMeshConnected && peers.isNotEmpty) {
            _activeNodeId = 'PURE P2P MESH (${peers.length} PEERS)';
          }
        });
        // A link to the peer we are waiting on may have just come up. This is
        // the event that actually delivers most pairing requests, because the
        // original send happens seconds before any link exists.
        if (peers.isNotEmpty) {
          _retryPendingPairRequests();
          // A squad member that reappears on the LAN is the event that actually
          // delivers most pending rekeys — the rotation typically happened while
          // they were out of range.
          _teamKeyDistributor.onRouteAvailable();
        }
      }),
      _telemetryService.myTelemetry.listen((tele) {
        if (!mounted) return;
        // Our own position changes every peer's range, not just our marker.
        setState(() => _myTelemetry = tele);
        _touchConversations();
      }),
      _telemetryService.teamTelemetry.listen((teamMap) {
        if (!mounted) return;
        setState(() => _teamTelemetry = teamMap);
        _touchConversations();
      }),
      _telemetryService.rejections.listen(_logRejection),
      _callService.stateChanges.listen(_onCallStateChanged),
      _callService.renderersChanged.listen((_) => _callRouteRevision.value++),
      _callService.callEnded.listen(_onCallEnded),
    ]);

    _meshClient.start();
    await _p2pMeshEngine.start();
    await _telemetryService.startReporting();

    // Anything left pending from a previous run resumes retrying now.
    _schedulePairRetries();

    if (mounted) {
      setState(() {
        _myProfileInitialized = true;
        _isLoading = false;
      });
    }
  }

  /// Records envelopes that failed verification.
  ///
  /// Rejections are surfaced rather than dropped silently: a burst of bad
  /// signatures on a shared network is something an operator should see.
  void _logRejection(RejectedMessage rejected) {
    switch (rejected.reason) {
      case RejectionReason.badSignature:
        _addEventLog(
          'SECURITY: FORGED ENVELOPE REJECTED',
          'Envelope claiming to be from ${rejected.envelope.senderId} failed '
              'signature verification (${rejected.detail}).',
          EventSeverity.security,
        );
      case RejectionReason.unknownSender:
        debugPrint('[SECURITY] Dropped traffic from unpaired ${rejected.envelope.senderId}');
      case RejectionReason.decryptionFailed:
        debugPrint('[SECURITY] Undecryptable ${rejected.envelope.type} from '
            '${rejected.envelope.senderId}: ${rejected.detail}');
      case RejectionReason.notForMe:
      case RejectionReason.malformed:
        break;
    }
  }

  Future<void> _processIncomingMessage(C2Message msg) async {
    if (!mounted) return;

    // Telemetry is verified and applied inside TelemetryService.
    if (msg.type == MessageType.telemetry) return;

    // PTT and live call audio are handled by PttAudioService, which runs the
    // same verification. Signalling that changes call state is handled here.
    if (msg.type == MessageType.pairRequest) {
      await _handlePairRequest(msg);
      return;
    }

    final result = await _channel.open(msg);
    if (result is RejectedMessage) {
      _logRejection(result);
      return;
    }

    final opened = result as OpenedMessage;
    final sender = opened.sender!;

    // Control payloads are JSON objects with an "action" field. They are now
    // authenticated exactly like chat: signed by a paired contact and sealed
    // under a key derived from our stored copy of their key material.
    Map<String, dynamic>? control;
    try {
      final decoded = jsonDecode(opened.plaintext);
      if (decoded is Map<String, dynamic> && decoded.containsKey('action')) {
        control = decoded;
      }
    } catch (_) {
      // Not a control payload; treated as message content below.
    }

    if (control != null) {
      await _handleControlPayload(control, opened, sender);
      return;
    }

    switch (msg.type) {
      case MessageType.callSignaling:
        // WebRTC signalling arrives as a JSON control payload and is handled
        // above. A completed voice transmission is content: it belongs in the
        // conversation alongside the text messages around it.
        if (opened.plaintext.startsWith('PTT_STOP:')) {
          await _recordVoiceMessage(opened, sender, Audience.direct(sender));
        }
      case MessageType.sosAlert:
        _handleSosAlert(sender);
      case MessageType.chat1to1:
        await _handleIncomingChat(opened, sender, 'MESSAGE FROM', Audience.direct(sender));
      case MessageType.chatGroup:
        if (opened.plaintext.startsWith('PTT_STOP:')) {
          await _recordVoiceMessage(opened, sender, const Audience.squad());
        } else {
          await _handleIncomingChat(
              opened, sender, 'GROUP MESSAGE FROM', const Audience.squad());
        }
      case MessageType.broadcast:
        if (opened.plaintext.startsWith('PTT_STOP:')) {
          await _recordVoiceMessage(opened, sender, const Audience.broadcast());
        } else {
          await _handleIncomingChat(
              opened, sender, 'OPERATIONAL BROADCAST FROM', const Audience.broadcast());
        }
      case MessageType.telemetry:
      case MessageType.waypoint:
      case MessageType.pairRequest:
        break;
    }
  }

  Future<void> _handleControlPayload(
    Map<String, dynamic> control,
    OpenedMessage opened,
    OperatorProfile sender,
  ) async {
    switch (control['action']) {
      case 'PAIR_ACK':
        await _handlePairAck(control, sender);

      case 'UNPAIR_AND_PURGE':
        // Only affects the contact who sent it. An operator can remove
        // themselves from our directory; they cannot remove anyone else, and
        // a broadcast can no longer wipe a whole squad's contacts.
        _handleIncomingRemoteUnpair(sender.id, sender.callsign);

      case 'TEAM_KEY_SYNC':
        // Convergence reply from a peer we just paired with. Merging is
        // idempotent and order-independent, so this terminates in one round.
        final syncSecret = control['group_secret'] as String?;
        final syncEpoch = control['group_epoch'] as int?;
        if (syncSecret != null && syncEpoch != null) {
          final adopted = await _teamEngine.mergeWithPeerSecret(syncSecret, syncEpoch);
          if (adopted) {
            debugPrint('[PAIRING] Adopted team key from ${sender.callsign}');
          }
          unawaited(_telemetryService.pushNow());
        }

      case 'GROUP_REKEY':
        final secret = control['group_secret'] as String?;
        final epoch = control['group_epoch'] as int?;
        if (secret != null && epoch != null && await _teamEngine.adoptRekey(secret, epoch)) {
          _addEventLog(
            'TEAM KEY ROTATED',
            'Adopted new team key (epoch $epoch) announced by ${sender.callsign}',
            EventSeverity.info,
          );
        }
        // Acknowledge unconditionally, reporting whatever epoch we now hold.
        // adoptRekey refuses a key that is not strictly newer, and in that case
        // we are already at or ahead of the sender — so an ack carrying our
        // epoch is what stops them retrying forever.
        if (secret != null && epoch != null) {
          await _sendControl(sender, {
            'action': 'GROUP_REKEY_ACK',
            'group_epoch': _teamEngine.epoch,
          }, idPrefix: 'rekeyack');
        }

      case 'GROUP_REKEY_ACK':
        final ackedEpoch = control['group_epoch'];
        if (ackedEpoch is int &&
            await _teamKeyDistributor.acknowledge(sender.id, ackedEpoch)) {
          _addEventLog(
            'TEAM KEY CONFIRMED',
            '${sender.callsign} confirmed team key epoch $ackedEpoch'
                '${_teamKeyDistributor.hasPending ? '' : ' — all operators in sync'}',
            EventSeverity.info,
          );
        }

      case 'CALL_INITIATE_VOICE':
      case 'CALL_INITIATE_VIDEO':
      case 'CALL_ACCEPT':
      case 'CALL_DECLINE':
      case 'CALL_END':
      case 'CALL_ICE':
        await _callService.handleSignal(control, sender);

      case 'DELIVERY_ACK':
        final msgId = control['message_id'];
        if (msgId is String) _updateMessageStatus(msgId, MessageStatus.delivered);

      case 'READ_ACK':
        final msgId = control['message_id'];
        if (msgId is String) _updateMessageStatus(msgId, MessageStatus.read);

      default:
        debugPrint('[CONTROL] Ignored unknown action ${control['action']}');
    }
  }

  Future<void> _handleIncomingChat(
    OpenedMessage opened,
    OperatorProfile sender,
    String title,
    Audience audience,
  ) async {
    await _addGlobalMessage(opened.envelope);
    await _sendDeliveryReceipt(opened.envelope.id, sender);

    _addEventLog('MESSAGE RECEIVED', 'Message from ${sender.callsign}', EventSeverity.info);
    _triggerAudibleAndHapticAlert();

    final key = _conversationKey(audience);
    if (_openConversationKey != key) {
      setState(() {
        _unreadByConversation[key] = (_unreadByConversation[key] ?? 0) + 1;
      });

      _showInAppNotification(
        title: '$title ${sender.callsign}',
        message: opened.plaintext,
        color: audience.accent,
        onTap: () {
          _sendReadReceipt(opened.envelope.id, sender);
          _openConversation(audience);
        },
      );
    }
  }

  /// Files a received voice transmission into its conversation.
  Future<void> _recordVoiceMessage(
    OpenedMessage opened,
    OperatorProfile sender,
    Audience audience,
  ) async {
    await _addGlobalMessage(opened.envelope);

    final key = _conversationKey(audience);
    if (_openConversationKey == key) return;

    setState(() {
      _unreadByConversation[key] = (_unreadByConversation[key] ?? 0) + 1;
    });

    _showInAppNotification(
      title: 'VOICE FROM ${sender.callsign.toUpperCase()}',
      message: 'Tap to listen',
      color: audience.accent,
      onTap: () => _openConversation(audience),
    );
  }

  void _handleSosAlert(OperatorProfile sender) {
    setState(() => _activeSosOperatorCallsign = sender.callsign);
    _addEventLog(
      'EMERGENCY SOS',
      'Distress beacon received from ${sender.callsign}',
      EventSeverity.alert,
    );
    _showInAppNotification(
      title: 'ALERT: EMERGENCY SOS',
      message: 'Distress signal received from ${sender.callsign}',
      color: Colors.red,
    );
  }

  /// Reflects call-service state into the shell (ringtones, active tab).
  void _onCallStateChanged(CallState state) {
    if (!mounted) return;

    switch (state) {
      case CallState.dialing:
        PttAudioService.startRingbackTone();
        _presentCallScreen();

      case CallState.ringing:
        final peer = _callService.peerProfile;
        if (peer == null) return;
        PttAudioService.startRingtone();
        _addEventLog('INCOMING CALL', 'Incoming call from ${peer.callsign}', EventSeverity.info);
        _presentCallScreen();

      case CallState.connecting:
      case CallState.connected:
        // Order matters: the tone player holds a media-routed audio session
        // (push-to-talk playback defaults to the loudspeaker), and releasing it
        // resets the route. Re-assert the call's route once it has let go, or a
        // voice call comes up on speaker.
        PttAudioService.stopCallTones()
            .then((_) => _callService.applyDefaultAudioRoute());
        _presentCallScreen();

      case CallState.ended:
      case CallState.idle:
        PttAudioService.stopCallTones();
        _dismissCallScreen();
    }
  }

  /// The call screen is a full-screen route rather than a tab: a call takes
  /// over the device, and there is no longer a Voice tab for it to live in.
  void _presentCallScreen() {
    if (_callRouteOpen) return;
    _callRouteOpen = true;

    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => AnimatedBuilder(
            animation: Listenable.merge([_callTicker, _callRouteRevision]),
            builder: (context, child) => CallScreen(
              service: _callService,
              fallbackPeer: _callService.peerProfile,
              callDurationSecs: _callSeconds,
              useLoudspeaker: _callService.isSpeakerphone,
              onLoudspeakerChanged: _callService.setSpeakerphone,
              onHangUp: _callService.hangUp,
            ),
          ),
        ))
        .then((_) => _callRouteOpen = false);

    _startCallTimer();
  }

  void _dismissCallScreen() {
    _stopCallTimer();
    if (_callRouteOpen && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      _callRouteOpen = false;
    }
  }

  void _startCallTimer() {
    _callTimer?.cancel();
    _callSeconds = 0;
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_callService.state == CallState.connected) {
        _callSeconds++;
        _callTicker.value = _callSeconds;
      }
    });
  }

  void _stopCallTimer() {
    _callTimer?.cancel();
    _callTimer = null;
    _callSeconds = 0;
  }

  void _onCallEnded(CallEndReason reason) {
    final (title, detail, severity) = switch (reason) {
      CallEndReason.hangup => ('CALL ENDED', 'Call ended', EventSeverity.info),
      CallEndReason.declined => ('CALL DECLINED', 'Call was declined', EventSeverity.info),
      CallEndReason.peerGone => ('CALL DROPPED', 'The other operator disconnected', EventSeverity.warning),
      CallEndReason.failed => (
          'CALL FAILED',
          'Could not establish a direct media path. Both devices may be behind '
              'restrictive networks; a TURN relay would be needed.',
          EventSeverity.warning,
        ),
    };

    _addEventLog(title, detail, severity);

    if (reason == CallEndReason.failed && mounted) {
      _showInAppNotification(
        title: 'CALL FAILED',
        message: 'No direct route to the other operator on this network.',
        color: Colors.amberAccent,
      );
    }
  }

  /// Handles a bootstrap pairing request from an operator we have scanned or who
  /// has scanned us. Nothing is trusted until the operator approves it.
  Future<void> _handlePairRequest(C2Message msg) async {
    final applicant = await _channel.openPairRequest(msg);
    if (applicant == null) return;

    if (_findContact(applicant.id) != null || _activePairingDialogs.contains(applicant.id)) {
      return;
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(msg.encryptedBody) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final tokenId = (data['token_id'] as String?) ?? '';

    if (tokenId.isNotEmpty && _consumedPairingTokens.contains(tokenId)) {
      _notifyTokenReuseSecurityAlert(applicant, tokenId);
    } else {
      _showPairingApprovalDialog(applicant, tokenId);
    }
  }

  /// Completes pairing when the far end approves our request.
  Future<void> _handlePairAck(Map<String, dynamic> control, OperatorProfile sender) async {
    if (!_pendingPairRequests.remove(sender.id)) {
      // Not one we asked for.
      _addEventLog(
        'SECURITY: UNSOLICITED PAIRING ACK',
        'Discarded a pairing acknowledgement from ${sender.callsign} that no '
            'request was outstanding for.',
        EventSeverity.security,
      );
      return;
    }

    await _persistPendingPairRequests();
    _schedulePairRetries();

    // Converge on a single team key so both devices can read team traffic.
    //
    // The ack only carries the far end's secret, and merging picks the
    // lexicographically smaller of the two. That converges this device, but
    // leaves the far end holding its own value whenever ours is the winner —
    // so we must send the result back. Without this return leg, roughly half
    // of all pairings ended with mismatched team keys, and every piece of team
    // traffic between them silently failed to decrypt.
    final peerSecret = control['group_secret'] as String?;
    final peerEpoch = control['group_epoch'] as int?;
    if (peerSecret != null && peerEpoch != null) {
      await _teamEngine.mergeWithPeerSecret(peerSecret, peerEpoch);
    }

    await _sendControl(sender, {
      'action': 'TEAM_KEY_SYNC',
      'group_secret': _teamEngine.groupSecret,
      'group_epoch': _teamEngine.epoch,
    }, idPrefix: 'team-sync');

    // Let the new contact see us straight away rather than waiting for the
    // next heartbeat, which can be fifteen minutes out on a stationary device.
    unawaited(_telemetryService.pushNow());

    _addEventLog(
      'PAIRING COMPLETED',
      'Pairing with ${sender.callsign} confirmed by far end',
      EventSeverity.info,
    );
    _showPairingCompletedDialog(sender);
  }

  Future<void> _persistContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final serializable = _teamProfiles
        .where((p) => p.id != _myProfile.id)
        .map((p) => p.toJson())
        .toList();
    await prefs.setString('c2_contacts', jsonEncode(serializable));
  }

  Future<void> _addEventLog(String title, String details, EventSeverity severity) async {
    final log = C2EventLog(
      id: 'log-${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      details: details,
      severity: severity,
      timestamp: DateTime.now(),
    );

    setState(() {
      _eventLogs.insert(0, log); // Newest first
    });

    final prefs = await SharedPreferences.getInstance();
    final serializable = _eventLogs.map((l) => l.toJson()).toList();
    await prefs.setString('c2_event_logs', jsonEncode(serializable));
  }

  /// Sends a sealed delivery receipt to the sender.
  ///
  /// Receipts used to go out as plaintext BROADCAST envelopes, which the relay
  /// fanned out to every operator — telling the whole mesh who was talking to
  /// whom, and when. They are now 1:1 and encrypted like any other message.
  Future<void> _sendDeliveryReceipt(String messageId, OperatorProfile recipient) =>
      _sendControl(recipient, {
        'action': 'DELIVERY_ACK',
        'message_id': messageId,
      }, idPrefix: 'ack-del');

  Future<void> _sendReadReceipt(String messageId, OperatorProfile recipient) =>
      _sendControl(recipient, {
        'action': 'READ_ACK',
        'message_id': messageId,
      }, idPrefix: 'ack-read');

  /// Seals a control payload for one contact and sends it over both transports.
  Future<bool> _sendControl(
    OperatorProfile recipient,
    Map<String, dynamic> payload, {
    String idPrefix = 'ctl',
  }) async {
    try {
      final envelope = await _channel.sealDirect(
        type: MessageType.chat1to1,
        recipient: recipient,
        plaintext: jsonEncode(payload),
        idPrefix: idPrefix,
      );
      final sentMesh = _meshClient.sendMessage(envelope);
      final sentP2P = _p2pMeshEngine.sendP2PDirectMessage(envelope);
      return sentMesh || sentP2P;
    } catch (e) {
      debugPrint('[CONTROL] Failed to send ${payload['action']}: $e');
      return false;
    }
  }

  void _updateMessageStatus(String messageId, MessageStatus newStatus) {
    setState(() {
      final index = _globalMessages.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        _globalMessages[index] = _globalMessages[index].copyWith(newStatus: newStatus);
      }
    });
  }

  /// Unpairs a contact and tells them, so both directories stay in step.
  Future<void> _removeContactInitiatedByMe(String targetOpId) async {
    final peer = _findContact(targetOpId);
    if (peer == null) return;

    await _sendControl(peer, {
      'action': 'UNPAIR_AND_PURGE',
      'operator_id': _myProfile.id,
    }, idPrefix: 'unpair');

    await _performLocalContactRemoval(targetOpId, peer.callsign);
    _addEventLog(
      'CONTACT UNPAIRED',
      'Unpaired and deleted contact ${peer.callsign} (${peer.id})',
      EventSeverity.warning,
    );

    // Rotate the team key so the removed operator cannot read future team
    // traffic, and hand the new key to everyone who is left. The old build
    // ratcheted locally and told nobody, which just made this device unable to
    // read its own squad's telemetry until it was restarted.
    await _rotateAndDistributeTeamKey();
  }

  Future<void> _rotateAndDistributeTeamKey() async {
    final remaining = _teamProfiles.where((p) => p.id != _myProfile.id).toList();
    if (remaining.isEmpty) return;

    await _teamEngine.rotate();

    final report = await _teamKeyDistributor.distributeToAll(remaining);

    if (!report.isComplete) {
      _addEventLog(
        'TEAM KEY ROTATION INCOMPLETE',
        'New team key (epoch ${_teamEngine.epoch}) is unconfirmed for '
            '${report.stillPending} of ${remaining.length} operators. Delivery '
            'is retried whenever a route to them appears, and each is tracked '
            'until it acknowledges.',
        EventSeverity.warning,
      );
    } else {
      _addEventLog(
        'TEAM KEY ROTATED',
        'Rotated team key to epoch ${_teamEngine.epoch} and confirmed with '
            '${remaining.length} operator(s)',
        EventSeverity.info,
      );
    }
  }

  /// Sends the current team key to one contact. Wired into
  /// [TeamKeyDistributor], which decides who needs it and when to retry.
  Future<bool> _sendTeamKeyTo(OperatorProfile recipient) => _sendControl(
        recipient,
        {
          'action': 'GROUP_REKEY',
          'group_secret': _teamEngine.groupSecret,
          'group_epoch': _teamEngine.epoch,
        },
        idPrefix: 'rekey',
      );

  Future<void> _persistPendingRekeys(Set<String> pending) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('c2_pending_rekeys', jsonEncode(pending.toList()));
  }

  /// Handles a verified unpair notice from a contact.
  void _handleIncomingRemoteUnpair(String opId, String callsign) {
    _performLocalContactRemoval(opId, callsign);
    _addEventLog(
      'REMOTE UNPAIR RECEIVED',
      'Operator $callsign un-paired from your squad directory',
      EventSeverity.warning,
    );

    SystemSound.play(SystemSoundType.alert);
    _showInAppNotification(
      title: '⚠️ OPERATOR UNPAIRED & REMOVED',
      message: 'Operator $callsign un-paired from squad directory. Contact removed.',
      color: Colors.amberAccent,
    );
  }

  Future<void> _performLocalContactRemoval(String opId, String callsign) async {
    final removed = _findContact(opId);

    setState(() {
      _teamProfiles.removeWhere((p) => p.id == opId);
      _teamTelemetry.remove(opId);
      if (_activeCallPeer?.id == opId) {
        _activeCallPeer = null;
      }
    });

    _pendingPairRequests.remove(opId);
    await _persistPendingPairRequests();
    // No longer a contact, so there is no team key left to owe them.
    await _teamKeyDistributor.forget(opId);
    _telemetryService.forgetOperator(opId);
    PttAudioService.forgetOperator(opId);
    if (removed != null) _pairwiseEngine.forgetPeer(removed.kexPublicKey);

    await _persistContacts();
  }

  /// Notifies every contact that this device is being wiped.
  ///
  /// Addressed individually rather than broadcast: the old broadcast form was
  /// an unauthenticated packet that erased contacts on every device that saw it.
  Future<void> _notifyContactsOfPurge() async {
    for (final peer in _teamProfiles.where((p) => p.id != _myProfile.id)) {
      await _sendControl(peer, {
        'action': 'UNPAIR_AND_PURGE',
        'operator_id': _myProfile.id,
      }, idPrefix: 'purge');
    }
  }

  /// Bounds stored history so a long deployment cannot grow it without limit.
  static const _maxStoredMessages = 1000;

  Future<void> _addGlobalMessage(C2Message msg) async {
    if (_globalMessages.any((m) => m.id == msg.id)) return;

    setState(() {
      _globalMessages.add(msg);
      if (_globalMessages.length > _maxStoredMessages) {
        _globalMessages.removeRange(0, _globalMessages.length - _maxStoredMessages);
      }
    });

    // Stored in the local form, which keeps the decrypted text. Persisting the
    // wire form instead meant every restored message rendered as "Decryption
    // Failed" after a restart, because the plaintext was never written.
    _touchConversations();

    final prefs = await SharedPreferences.getInstance();
    final serializable = _globalMessages.map((m) => m.toStorageJson()).toList();
    await prefs.setString('c2_chat_history', jsonEncode(serializable));
  }

  void _notifyTokenReuseSecurityAlert(OperatorProfile applicant, String tokenId) {
    if (_teamProfiles.any((p) => p.id == applicant.id) || _activePairingDialogs.contains(applicant.id)) return;
    _activePairingDialogs.add(applicant.id);

    _addEventLog(
      'SECURITY WARNING: PAIRING CODE REUSE',
      'Operator ${applicant.callsign} submitted previously consumed pairing code ($tokenId). User review requested.',
      EventSeverity.security,
    );
    SystemSound.play(SystemSoundType.alert);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: C2Colors.slateCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Colors.amberAccent, width: 2),
        ),
        title: const Row(
          children: [
            Icon(Icons.gpp_maybe, color: Colors.amberAccent, size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'SECURITY WARNING: REUSED PAIRING CODE',
                style: TextStyle(color: Colors.amberAccent, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Operator: ${applicant.callsign} (${applicant.name})', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Token ID: $tokenId', style: const TextStyle(color: Colors.white70, fontSize: 11)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.4)),
              ),
              child: const Text(
                '⚠️ WARNING: This pairing token was previously consumed. Reusing pairing codes can expose security keys to unauthorized devices on the mesh network. Do you trust this operator and wish to accept pairing anyway?',
                style: TextStyle(color: Colors.amberAccent, fontSize: 11),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _activePairingDialogs.remove(applicant.id);
              Navigator.pop(ctx);
              _addEventLog('PAIRING REJECTED', 'User rejected reused pairing token ($tokenId) from ${applicant.callsign}', EventSeverity.warning);
            },
            child: const Text('REJECT & BLOCK', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.amberAccent, foregroundColor: Colors.black),
            icon: const Icon(Icons.check_circle_outline, size: 16),
            label: const Text('ALLOW & PAIR ANYWAY', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () {
              _activePairingDialogs.remove(applicant.id);
              Navigator.pop(ctx);
              _forceAddContact(applicant, tokenId: tokenId);
            },
          ),
        ],
      ),
    ).then((_) => _activePairingDialogs.remove(applicant.id));
  }

  /// Adds a contact after the operator overrode a pairing-code reuse warning.
  Future<void> _forceAddContact(OperatorProfile newProfile, {String tokenId = ''}) async {
    _addEventLog(
      'PAIRING APPROVED (OVERRIDE)',
      'Overrode a pairing-code reuse warning and paired with ${newProfile.callsign}',
      EventSeverity.warning,
    );
    await _acceptPairing(newProfile, tokenId);
  }

  void _triggerAudibleAndHapticAlert() {
    PttAudioService.playMessageArrivalSound();
    SystemSound.play(SystemSoundType.alert);
    SystemSound.play(SystemSoundType.click);
    HapticFeedback.heavyImpact();
    HapticFeedback.vibrate();
  }

  void _showInAppNotification({
    required String title,
    required String message,
    required Color color,
    VoidCallback? onTap,
  }) {
    _triggerAudibleAndHapticAlert();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: C2Colors.slateCard,
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: color),
        ),
        content: InkWell(
          onTap: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            onTap?.call();
          },
          child: Row(
            children: [
              Icon(Icons.notifications_active, color: color, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
                    Text(message, style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ],
                ),
              ),
              if (onTap != null)
                TextButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    onTap();
                  },
                  child: const Text('VIEW', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 11)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPairingApprovalDialog(OperatorProfile applicant, String tokenId) {
    if (_teamProfiles.any((p) => p.id == applicant.id) || _activePairingDialogs.contains(applicant.id)) return;
    _activePairingDialogs.add(applicant.id);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: C2Colors.slateCard,
        title: Row(
          children: [
            const Icon(Icons.security, color: Colors.cyanAccent, size: 20),
            const SizedBox(width: 8),
            Text('PAIRING REQUEST FROM ${applicant.callsign}', style: const TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Callsign: ${applicant.callsign}', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Operator ID: ${applicant.id}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
            const SizedBox(height: 12),
            const Text('SAFETY NUMBER', style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
            const SizedBox(height: 4),
            SelectableText(
              E2EEEngine.computeSafetyNumber(_myProfile.signPublicKey, applicant.signPublicKey),
              style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace', height: 1.5),
            ),
            const SizedBox(height: 12),
            const Text(
              'Read this number aloud with the other operator before approving. '
              'If it does not match on both devices, someone is intercepting the '
              'pairing — reject it.',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _activePairingDialogs.remove(applicant.id);
              Navigator.pop(ctx);
            },
            child: const Text('REJECT', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: C2Colors.emeraldAccent, foregroundColor: Colors.black),
            onPressed: () {
              _activePairingDialogs.remove(applicant.id);
              Navigator.pop(ctx);
              _acceptPairing(applicant, tokenId);
            },
            child: const Text('APPROVE & PAIR', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ).then((_) => _activePairingDialogs.remove(applicant.id));
  }

  void _showPairingCompletedDialog(OperatorProfile peer) {
    if (!mounted) return;

    _triggerAudibleAndHapticAlert();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: C2Colors.slateCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: C2Colors.emeraldAccent, width: 2),
          ),
          title: Row(
            children: [
              const Icon(Icons.check_circle, color: C2Colors.emeraldAccent, size: 28),
              const SizedBox(width: 10),
              const Text(
                'PAIRING COMPLETED',
                style: TextStyle(
                  color: C2Colors.emeraldAccent,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Operator ${peer.callsign} is now verified and added to your squad contacts.',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Text(
                'You can now message ${peer.callsign}, talk to them, and see '
                'their position on the map.',
                style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 16),

              // One clear next step rather than three "TEST ..." buttons, which
              // read as developer scaffolding to anyone actually using the app.
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyanAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.chat, size: 18),
                  label: Text('MESSAGE ${peer.callsign}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _openConversation(Audience.direct(peer));
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('DONE', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  /// Starts an outgoing call. Both media types run over the same WebRTC path.
  Future<void> _startCall(OperatorProfile peer, CallMedia media) =>
      _callService.startCall(peer, media);

  /// Called when the operator scans a pairing code.
  ///
  /// The scan is the out-of-band step: it delivers the peer's identity and
  /// key-agreement keys over a channel the operator controls, which is what
  /// makes the resulting session key meaningful. We store the contact, then
  /// send a signed request asking the far end to approve us in return.
  Future<void> _addContactDirectly(
    OperatorProfile newProfile, {
    String tokenId = '',
    bool sendPairRequest = true,
  }) async {
    if (newProfile.id == _myProfile.id) return;
    if (!newProfile.hasValidKeys) {
      _showInAppNotification(
        title: 'PAIRING CODE UNUSABLE',
        message: 'That code has no identity keys. The other device must be '
            'updated before it can pair.',
        color: Colors.redAccent,
      );
      return;
    }

    await _consumeToken(tokenId);
    await _storeContact(newProfile);

    if (!sendPairRequest) return;

    _pendingPairRequests.add(newProfile.id);
    await _persistPendingPairRequests();
    _schedulePairRetries();
    try {
      final request = await _channel.sealPairRequest(
        recipientId: newProfile.id,
        me: _myProfile,
        tokenId: tokenId,
      );
      _meshClient.sendMessage(request);
      _p2pMeshEngine.sendP2PDirectMessage(request);
    } catch (e) {
      debugPrint('[PAIRING] Failed to send request: $e');
    }

    _addEventLog(
      'PAIRING REQUEST SENT',
      'Sent pairing request to ${newProfile.callsign} (${newProfile.id})',
      EventSeverity.info,
    );
    _showInAppNotification(
      title: 'PAIRING REQUEST TRANSMITTED',
      message: 'Request sent to ${newProfile.callsign}. Waiting for approval...',
      color: Colors.cyanAccent,
    );
  }

  /// Approves an inbound pairing request: stores the contact and acknowledges,
  /// handing over the team key inside the now-established encrypted channel.
  Future<void> _acceptPairing(OperatorProfile applicant, String tokenId) async {
    await _consumeToken(tokenId);
    await _storeContact(applicant);

    await _sendControl(applicant, {
      'action': 'PAIR_ACK',
      'token_id': tokenId,
      'group_secret': _teamEngine.groupSecret,
      'group_epoch': _teamEngine.epoch,
    }, idPrefix: 'pair-ack');

    _addEventLog(
      'PAIRING APPROVED',
      'Paired with ${applicant.callsign} (${applicant.id})',
      EventSeverity.info,
    );
    unawaited(_telemetryService.pushNow());
    _showPairingCompletedDialog(applicant);
  }

  Future<void> _storeContact(OperatorProfile contact) async {
    setState(() {
      final idx = _teamProfiles.indexWhere((p) => p.id == contact.id);
      if (idx >= 0) {
        _teamProfiles[idx] = contact;
      } else {
        _teamProfiles.add(contact);
      }
    });
    await _persistContacts();
  }

  Future<void> _consumeToken(String tokenId) async {
    if (tokenId.isEmpty) return;
    _consumedPairingTokens.add(tokenId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'c2_consumed_pairing_tokens',
      jsonEncode(_consumedPairingTokens.toList()),
    );
  }

  /// Seals an SOS beacon under the team key and sends it on both transports.
  Future<void> _broadcastSos() async {
    try {
      final envelope = await _channel.sealTeam(
        type: MessageType.sosAlert,
        plaintext: jsonEncode({
          'action': 'SOS',
          'callsign': _myProfile.callsign,
          'latitude': _myTelemetry?.latitude,
          'longitude': _myTelemetry?.longitude,
        }),
        idPrefix: 'sos',
      );
      _meshClient.sendMessage(envelope);
      _p2pMeshEngine.sendP2PDirectMessage(envelope);
      _addEventLog('EMERGENCY SOS BROADCAST', 'SOS distress beacon broadcast to squad', EventSeverity.alert);
    } catch (e) {
      debugPrint('[SOS] Failed to broadcast: $e');
      _addEventLog('SOS BROADCAST FAILED', 'Could not seal SOS beacon: $e', EventSeverity.alert);
    }
  }

  void _triggerSosEmergency() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C2Colors.slateCard,
        title: const Text('EMERGENCY SOS DISTRESS', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16)),
        content: const Text('Broadcast emergency SOS distress beacon with your exact GPS location to all squad members immediately?', style: TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCEL', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              _broadcastSos();

              setState(() {
                _activeSosOperatorCallsign = _myProfile.callsign;
              });

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  backgroundColor: Colors.red,
                  content: Text('EMERGENCY SOS SIGNAL BROADCAST TO SQUAD', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              );
            },
            child: const Text('BROADCAST SOS NOW', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pairRetryTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

    if (_myProfileInitialized) {
      _teamKeyDistributor.dispose();
      // Fire-and-forget: dispose() cannot await, but each of these closes its
      // own sockets, timers and stream controllers rather than leaking them.
      unawaited(PttAudioService.disposeGlobalListener());
      unawaited(_callService.dispose());
      unawaited(_telemetryService.dispose());
      unawaited(_p2pMeshEngine.dispose());
      unawaited(_meshClient.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failure = _storageFailure;
    if (failure != null) return _buildStorageFailureScreen(failure);

    final trustFailure = _trustAnchorFailure;
    if (trustFailure != null) return _buildTrustAnchorFailureScreen(trustFailure);

    if (_isLoading) {
      return const Scaffold(
        backgroundColor: C2Colors.slateBg,
        body: Center(
          child: CircularProgressIndicator(color: Colors.cyanAccent),
        ),
      );
    }

    if (!_myProfileInitialized) {
      return OnboardingView(
        onSetupComplete: (profile) => _initializeServices(profile),
      );
    }

    final pairedP2pPeersCount = _p2pMeshEngine.activePeers.keys.where((opId) {
      return _teamProfiles.any((p) => (p.id == opId || p.callsign.toUpperCase() == opId.toUpperCase()) && p.id != _myProfile.id);
    }).length;

    final List<Widget> pages = [
      TacticalMapView(
        myProfile: _myProfile,
        myTelemetry: _myTelemetry,
        teamProfiles: _teamProfiles,
        teamTelemetry: _teamTelemetry,
        teamBreadcrumbs: _telemetryService.teamBreadcrumbs,
        isMeshConnected: _isMeshConnected,
        isP2pConnected: pairedP2pPeersCount > 0,
        activeNodeId: _activeNodeId,
        p2pPeersCount: pairedP2pPeersCount,
        activeSosOperatorCallsign: _activeSosOperatorCallsign,
        onTriggerSos: _triggerSosEmergency,
        onStartVoiceCall: (peer) => _startCall(peer, CallMedia.voice),
        onStartVideoCall: (peer) => _startCall(peer, CallMedia.video),
        onOpenChat: (peer) => _openConversation(Audience.direct(peer)),
      ),
      ConversationList(
        conversations: _buildConversations(),
        onOpen: _openConversation,
        onShowDetails: (a) {
          if (a.isDirect) _showContactActionSheet(a.peer!);
        },
        onAddOperator: _openPairingFlow,
        ptt: _pttRecorder,
        onVoiceRecorded: _finishRowTransmission,
        onStartCall: (audience, media) {
          if (audience.isDirect) _startCall(audience.peer!, media);
        },
      ),
      SettingsView(
        myProfile: _myProfile,
        teamProfiles: _teamProfiles,
        eventLogs: _eventLogs,
        onProfileUpdated: (updated) async {
          setState(() {
            _myProfile = updated;
          });
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('c2_my_profile', jsonEncode(updated.toJson()));
          _addEventLog('PROFILE UPDATED', 'Updated callsign to ${updated.callsign}', EventSeverity.info);
        },
        onRemoveContact: (opId) => _removeContactInitiatedByMe(opId),
        onClearLogs: () async {
          setState(() {
            _eventLogs.clear();
          });
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove('c2_event_logs');
        },
        onClearData: () async {
          await _notifyContactsOfPurge();

          final prefs = await SharedPreferences.getInstance();
          await prefs.clear();

          // Key material lives in secure storage, which prefs.clear() does not
          // touch. Leaving it behind would let a re-provisioned device keep
          // reading traffic addressed to the identity it just discarded.
          await OperatorIdentity.destroy();
          await TeamGroupEngine.destroy();

          // prefs.clear() drops the persisted list, but the live distributor is
          // still holding it in memory with a retry timer running. Onboarding
          // builds a fresh one.
          _teamKeyDistributor.dispose();

          setState(() {
            _myProfileInitialized = false;
            _globalMessages.clear();
            _eventLogs.clear();
            _consumedPairingTokens.clear();
            _pendingPairRequests.clear();
            _teamProfiles.clear();
          });
        },
      ),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentTab.index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTab.index,
        backgroundColor: const Color(0xFF1E293B),
        indicatorColor: Colors.cyan.withValues(alpha: 0.25),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (index) =>
            setState(() => _currentTab = AppTab.values[index]),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.map_outlined, color: Colors.white54),
            selectedIcon: Icon(Icons.map, color: Colors.cyanAccent),
            label: 'Map',
          ),
          NavigationDestination(
            icon: _unreadBadge(const Icon(Icons.forum_outlined, color: Colors.white54)),
            selectedIcon: _unreadBadge(const Icon(Icons.forum, color: Colors.cyanAccent)),
            label: 'Squad',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined, color: Colors.white54),
            selectedIcon: Icon(Icons.settings, color: Colors.cyanAccent),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  /// Total unread across every conversation.
  Widget _unreadBadge(Widget icon) {
    final total = _unreadByConversation.values.fold<int>(0, (a, b) => a + b);
    if (total == 0) return icon;
    return Badge(
      label: Text('$total'),
      backgroundColor: Colors.cyanAccent,
      textColor: Colors.black,
      child: icon,
    );
  }

  /// Re-sends outstanding pairing requests over whatever transport now exists.
  ///
  /// Called when a direct peer link comes up, when the relay connects, and on a
  /// slow timer as a backstop. Sending a pairing request is idempotent: the far
  /// end ignores duplicates while its approval dialog is open, and drops them
  /// outright once we are already a contact.
  Future<void> _retryPendingPairRequests() async {
    if (_pendingPairRequests.isEmpty) {
      _pairRetryTimer?.cancel();
      _pairRetryTimer = null;
      return;
    }

    for (final operatorId in _pendingPairRequests.toList()) {
      final contact = _findContact(operatorId);
      if (contact == null || !contact.hasValidKeys) {
        _pendingPairRequests.remove(operatorId);
        continue;
      }

      try {
        final request = await _channel.sealPairRequest(
          recipientId: operatorId,
          me: _myProfile,
          tokenId: '',
        );
        final sentMesh = _meshClient.sendMessage(request);
        final sentP2P = _p2pMeshEngine.sendP2PDirectMessage(request);
        if (sentMesh || sentP2P) {
          debugPrint('[PAIRING] Re-sent pairing request to $operatorId');
        }
      } catch (e) {
        debugPrint('[PAIRING] Retry failed for $operatorId: $e');
      }
    }
  }

  /// Backstop polling for a pairing the peer has not answered yet.
  ///
  /// Bounded: an abandoned pairing should not leave the device chattering
  /// indefinitely. Once the ticks run out the request stays pending and is
  /// still retried whenever a route to that operator appears.
  void _schedulePairRetries() {
    _pairRetryTimer?.cancel();
    if (_pendingPairRequests.isEmpty) return;

    _pairRetriesRemaining = 20; // ~5 minutes at 15s intervals.
    _pairRetryTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (_pendingPairRequests.isEmpty || _pairRetriesRemaining-- <= 0) {
        timer.cancel();
        _pairRetryTimer = null;
        return;
      }
      _retryPendingPairRequests();
    });
  }

  Future<void> _persistPendingPairRequests() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('c2_pending_pair_requests', jsonEncode(_pendingPairRequests.toList()));
  }

  /// Shown instead of the app when key storage is unavailable.
  Widget _buildStorageFailureScreen(SecureStorageUnavailable failure) {
    return Scaffold(
      backgroundColor: C2Colors.slateBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.gpp_bad_outlined, color: Colors.redAccent, size: 64),
              const SizedBox(height: 20),
              const Text(
                'SECURE STORAGE UNAVAILABLE',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                failure.detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: C2Colors.slateCard,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.4)),
                ),
                child: Text(
                  failure.remedy,
                  style: const TextStyle(color: Colors.amberAccent, fontSize: 12, height: 1.5),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Vector C2 will not start without protected key storage. Running '
                'without it would mean your identity keys sit unprotected on this '
                'device, so this is refused rather than worked around.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyanAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                ),
                icon: const Icon(Icons.refresh),
                label: const Text('RETRY', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () {
                  setState(() {
                    _storageFailure = null;
                    _isLoading = true;
                  });
                  _loadPersistedState();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shown when RELAY_CA_PEM_BASE64 will not parse.
  ///
  /// Deliberately offers no RETRY: the CA is a compile-time constant, so
  /// nothing an operator can do on the device changes the outcome. Starting
  /// anyway would silently fall back to platform roots and make every pinned
  /// node look unreachable.
  Widget _buildTrustAnchorFailureScreen(RelayTrustAnchorInvalid failure) {
    return Scaffold(
      backgroundColor: C2Colors.slateBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.gpp_bad_outlined, color: Colors.redAccent, size: 64),
              const SizedBox(height: 20),
              const Text(
                'RELAY CA IS INVALID',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                failure.detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: C2Colors.slateCard,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.4)),
                ),
                child: const Text(
                  'Rebuild with a correct --dart-define=RELAY_CA_PEM_BASE64, or omit '
                  'it to use the platform root store. See DEPLOYMENT.md.',
                  style: TextStyle(color: Colors.amberAccent, fontSize: 12, height: 1.5),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'This build pins a relay certificate authority that cannot be read. '
                'Continuing would leave every pinned node looking unreachable with '
                'no indication why, so it is refused instead.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens a conversation: messages, push-to-talk, and calls in one place.
  Future<void> _openConversation(Audience audience) async {
    final key = _conversationKey(audience);
    setState(() {
      _openConversationKey = key;
      _unreadByConversation.remove(key);
    });

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimatedBuilder(
          // Rebuild as messages and telemetry arrive while the thread is open.
          animation: _conversationRevision,
          builder: (context, child) => ConversationView(
            audience: audience,
            messages: _globalMessages,
            telemetry: audience.isDirect ? _teamTelemetry[audience.peer!.id] : null,
            channel: _channel,
            ptt: _pttRecorder,
            onSendText: (text) => _sendConversationMessage(audience, text),
            onVoiceRecorded: _recordOwnVoiceMessage,
            onStartCall: audience.isDirect
                ? (media) => _startCall(audience.peer!, media)
                : null,
            onShowDetails: audience.isDirect
                ? () => _showContactActionSheet(audience.peer!)
                : null,
          ),
        ),
      ),
    );

    if (mounted) setState(() => _openConversationKey = null);
  }

  /// Ends a transmission started from a squad row and files the result.
  Future<void> _finishRowTransmission(Audience audience) async {
    final clip = await _pttRecorder.stop(audience);
    if (clip == null) return;
    await _recordOwnVoiceMessage(audience, clip.duration, clip.audioData);
  }

  /// Files a transmission this device just sent into its conversation.
  ///
  /// PttRecorder has already sealed and sent it; this reconstructs the same
  /// payload locally so the sender sees their own clip in the thread, playable,
  /// exactly as the recipient will.
  Future<void> _recordOwnVoiceMessage(
    Audience audience,
    Duration duration,
    List<int> audio,
  ) async {
    final payload = 'PTT_STOP:${jsonEncode({
          'action': 'PTT_STOP',
          'audio_base64': base64Encode(audio),
          'duration_ms': duration.inMilliseconds,
          'callsign': _myProfile.callsign,
        })}';

    await _addGlobalMessage(C2Message(
      id: 'voice-${DateTime.now().microsecondsSinceEpoch}',
      type: audience.isDirect ? MessageType.callSignaling : audience.messageType,
      senderId: _myProfile.id,
      senderSignKey: _identity.signPublicKey,
      recipientId: audience.peer?.id,
      groupId: audience.isDirect ? null : _teamEngine.groupId,
      encryptedBody: '',
      decryptedBody: payload,
      timestamp: DateTime.now(),
      isMe: true,
      status: MessageStatus.sent,
    ));
  }

  /// Bumped whenever state an open conversation renders from has changed.
  final ValueNotifier<int> _conversationRevision = ValueNotifier(0);

  void _touchConversations() => _conversationRevision.value++;

  Future<void> _sendConversationMessage(Audience audience, String text) async {
    try {
      final C2Message msg;
      if (audience.isDirect) {
        msg = await _channel.sealDirect(
          type: MessageType.chat1to1,
          recipient: audience.peer!,
          plaintext: text,
        );
      } else {
        msg = await _channel.sealTeam(type: audience.messageType, plaintext: text);
      }

      final sentMesh = _meshClient.sendMessage(msg);
      final sentP2P = _p2pMeshEngine.sendP2PDirectMessage(msg);
      await _addGlobalMessage(
        msg.copyWith(
          newStatus: (sentMesh || sentP2P) ? MessageStatus.sent : MessageStatus.sending,
        ),
      );
    } catch (e) {
      debugPrint('[COMMS] Send failed: $e');
      if (mounted) {
        _showInAppNotification(
          title: 'SEND FAILED',
          message: '$e',
          color: Colors.redAccent,
        );
      }
    }
  }

  /// Builds the squad list: one row per operator, plus the two channels.
  List<ConversationSummary> _buildConversations() {
    C2Message? lastFor(Audience a) {
      C2Message? latest;
      for (final m in _globalMessages) {
        // Same content rule the thread uses, so a preview can never show
        // signalling the conversation itself would hide.
        if (!a.includes(m, _myProfile.id)) continue;
        if (!Audience.isDisplayableContent(m)) continue;
        if (latest == null || m.timestamp.isAfter(latest.timestamp)) latest = m;
      }
      return latest;
    }

    final contacts = _teamProfiles.where((p) => p.id != _myProfile.id).toList();

    // Range is only meaningful when both ends have a fix.
    const geo = Distance();
    final mine = _myTelemetry;

    double? rangeTo(Telemetry? theirs) {
      if (mine == null || theirs == null) return null;
      if (mine.latitude == 0 && mine.longitude == 0) return null;
      return geo.as(
        LengthUnit.Meter,
        LatLng(mine.latitude, mine.longitude),
        LatLng(theirs.latitude, theirs.longitude),
      );
    }

    final rows = <ConversationSummary>[
      for (final c in contacts)
        ConversationSummary(
          audience: Audience.direct(c),
          telemetry: _teamTelemetry[c.id],
          distanceMeters: rangeTo(_teamTelemetry[c.id]),
          lastMessage: lastFor(Audience.direct(c)),
          unread: _unreadByConversation[_conversationKey(Audience.direct(c))] ?? 0,
        ),
    ];

    // Most recently active operator first; those never heard from sink down.
    rows.sort((a, b) {
      final at = a.lastMessage?.timestamp ?? a.telemetry?.timestamp;
      final bt = b.lastMessage?.timestamp ?? b.telemetry?.timestamp;
      if (at == null && bt == null) return a.title.compareTo(b.title);
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });

    return [
      ...rows,
      ConversationSummary(
        audience: const Audience.squad(),
        lastMessage: lastFor(const Audience.squad()),
        unread: _unreadByConversation['squad'] ?? 0,
        memberCount: _teamProfiles.length,
      ),
      ConversationSummary(
        audience: const Audience.broadcast(),
        lastMessage: lastFor(const Audience.broadcast()),
        unread: _unreadByConversation['broadcast'] ?? 0,
      ),
    ];
  }

  /// Opens pairing as a full screen, which is what QR scanning needs.
  void _openPairingFlow() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QrPairingView(
          myProfile: _myProfile,
          channel: _channel,
          onContactAdded: (peer, tokenId) {
            _addContactDirectly(peer, tokenId: tokenId, sendPairRequest: true);
            Navigator.of(context).maybePop();
          },
        ),
      ),
    );
  }

  void _showContactActionSheet(OperatorProfile peer) {
    final isMe = peer.id == _myProfile.id;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      // Without these the sheet is capped near half the screen and does not
      // scroll, so its lower entries — including "Unpair & Delete Contact",
      // which sits last as a destructive action — were simply unreachable on a
      // phone. There was no way to remove a contact at all.
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: C2Colors.slateCard,
                      child: Text(
                        peer.callsign.substring(0, peer.callsign.length >= 2 ? 2 : peer.callsign.length),
                        style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            peer.callsign,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          Text(
                            isMe ? 'Your Local Device Profile' : 'Verified Squad Contact',
                            style: TextStyle(color: isMe ? Colors.cyanAccent : C2Colors.emeraldAccent, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 20),

                if (!isMe) ...[
                  ListTile(
                    leading: const Icon(Icons.chat, color: Colors.cyanAccent),
                    title: const Text('Send Text Message', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Open 1-to-1 comms chat', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _openConversation(Audience.direct(peer));
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.phone, color: C2Colors.emeraldAccent),
                    title: const Text('Voice Call', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Start full-duplex voice call', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _startCall(peer, CallMedia.voice);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.videocam, color: Colors.purpleAccent),
                    title: const Text('Video Call', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Camera and microphone, peer to peer', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _startCall(peer, CallMedia.video);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.map, color: Colors.amberAccent),
                    title: const Text('View Location on Map', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Center tactical map on operator GPS', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _currentTab = AppTab.map;
                      });
                    },
                  ),
                  const Divider(color: Colors.white12, height: 16),
                  ListTile(
                    leading: const Icon(Icons.verified_user, color: C2Colors.emeraldAccent),
                    title: const Text('Verify Safety Number', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Confirm nobody is intercepting this contact', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showSafetyNumberDialog(peer);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.person_remove, color: Colors.redAccent),
                    title: const Text('Unpair & Delete Contact', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Remove from squad, and tell them', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _confirmUnpair(peer);
                    },
                  ),
                ] else ...[
                  ListTile(
                    leading: const Icon(Icons.settings, color: Colors.cyanAccent),
                    title: const Text('Manage Local Profile', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Edit callsign and profile settings', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _currentTab = AppTab.settings;
                      });
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Shows the shared safety number for out-of-band verification.
  void _showSafetyNumberDialog(OperatorProfile peer) {
    final number = E2EEEngine.computeSafetyNumber(
      _myProfile.signPublicKey,
      peer.signPublicKey,
    );

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C2Colors.slateCard,
        title: Text(
          'VERIFY ${peer.callsign}',
          style: const TextStyle(color: Colors.cyanAccent, fontSize: 14, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Read this number aloud with the other operator. If it matches on '
              'both devices, your connection is private. If it does not, someone '
              'is intercepting it — unpair and try again in person.',
              style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: C2Colors.emeraldAccent.withValues(alpha: 0.4)),
              ),
              child: SelectableText(
                number,
                style: const TextStyle(
                  color: C2Colors.emeraldAccent,
                  fontSize: 15,
                  fontFamily: 'monospace',
                  height: 1.8,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CLOSE', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// Confirms before unpairing: it removes history on both devices and rotates
  /// the team key, none of which is recoverable by tapping again.
  void _confirmUnpair(OperatorProfile peer) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C2Colors.slateCard,
        title: Text(
          'UNPAIR ${peer.callsign}?',
          style: const TextStyle(color: Colors.redAccent, fontSize: 14, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'They will be removed from your squad and notified. You will stop '
          'seeing each other on the map. Pairing again needs a new code, in person.',
          style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              _removeContactInitiatedByMe(peer.id);
            },
            child: const Text('UNPAIR', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

}
