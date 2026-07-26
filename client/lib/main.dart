import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/operator_profile.dart';
import 'models/telemetry.dart';
import 'models/c2_message.dart';
import 'models/c2_event_log.dart';
import 'crypto/e2ee_engine.dart';
import 'crypto/mls_group_engine.dart';
import 'services/mesh_client.dart';
import 'services/p2p_mesh_engine.dart';
import 'services/ptt_audio_service.dart';
import 'services/telemetry_service.dart';
import 'ui/theme/c2_colors.dart';
import 'ui/map/tactical_map_view.dart';
import 'ui/chat/chat_view.dart';
import 'ui/chat/call_view.dart';
import 'ui/onboarding/qr_pairing_view.dart';
import 'ui/onboarding/onboarding_view.dart';
import 'ui/settings/settings_view.dart';

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

class MainShellView extends StatefulWidget {
  const MainShellView({super.key});

  @override
  State<MainShellView> createState() => _MainShellViewState();
}

class _MainShellViewState extends State<MainShellView> {
  int _currentIndex = 0;

  bool _isLoading = true;
  bool _myProfileInitialized = false;
  late OperatorProfile _myProfile;
  final List<OperatorProfile> _teamProfiles = [];
  final List<C2Message> _globalMessages = [];
  final List<C2EventLog> _eventLogs = [];
  final Set<String> _consumedPairingTokens = {};
  final Set<String> _activePairingDialogs = {};
  int _activeChatSubTab = 0;
  OperatorProfile? _activeChatPeer;
  OperatorProfile? _activeCallPeer;
  bool _isCallActive = false;

  late MeshClient _meshClient;
  late P2PMeshEngine _p2pMeshEngine;
  late TelemetryService _telemetryService;
  late E2EEEngine _cryptoEngine;
  late MLSGroupEngine _mlsGroupEngine;

  bool _isMeshConnected = false;
  String _activeNodeId = 'local-mesh-8080';
  Telemetry? _myTelemetry;
  Map<String, Telemetry> _teamTelemetry = {};
  String? _activeSosOperatorCallsign;

  static const String _cloudNodeEnv = String.fromEnvironment('CLOUD_MESH_NODE_URL', defaultValue: 'http://84ace.com:8080');
  static const String _nasNodeEnv = String.fromEnvironment('NAS_MESH_NODE_URL', defaultValue: 'http://nas.local:8080');
  static const String _localNodeEnv = String.fromEnvironment('LOCAL_MESH_NODE_URL', defaultValue: 'http://127.0.0.1:8080');
  static const String _fieldRouterEnv = String.fromEnvironment('FIELD_ROUTER_NODE_URL', defaultValue: 'http://field-router.local:8080');

  final List<String> candidateMeshNodes = [
    _cloudNodeEnv,
    _nasNodeEnv,
    _localNodeEnv,
    'http://192.168.1.100:8080',
    _fieldRouterEnv,
  ];

  @override
  void initState() {
    super.initState();
    _loadPersistedState();
  }

  Future<void> _loadPersistedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final profileJson = prefs.getString('c2_my_profile');
      final keysJson = prefs.getString('c2_keys');

      final consumedTokensJson = prefs.getString('c2_consumed_pairing_tokens');
      if (consumedTokensJson != null) {
        final List<dynamic> tokenList = jsonDecode(consumedTokensJson);
        _consumedPairingTokens.addAll(tokenList.cast<String>());
      }

      final logsJson = prefs.getString('c2_event_logs');
      if (logsJson != null) {
        final List<dynamic> logList = jsonDecode(logsJson);
        _eventLogs.clear();
        for (final l in logList) {
          _eventLogs.add(C2EventLog.fromJson(l));
        }
      }

      if (profileJson != null && keysJson != null) {
        final profileMap = jsonDecode(profileJson);
        final keysMap = jsonDecode(keysJson);
        final profile = OperatorProfile.fromJson(profileMap);

        _initializeServices(profile, loadedKeys: keysMap);
      } else {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (_) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _initializeServices(OperatorProfile profile, {Map<String, dynamic>? loadedKeys}) async {
    try {
      await [
        Permission.microphone,
        Permission.location,
        Permission.camera,
      ].request();
    } catch (_) {}

    Map<String, String> keys;
    if (loadedKeys != null) {
      keys = Map<String, String>.from(loadedKeys);
    } else {
      keys = E2EEEngine.generateKeyPair('operator-alpha-seed');
    }

    _myProfile = profile.copyWith(publicKey: keys['publicKey']!);

    _teamProfiles.clear();
    _teamProfiles.add(_myProfile);

    final prefs = await SharedPreferences.getInstance();
    final contactsJson = prefs.getString('c2_contacts');
    if (contactsJson != null) {
      final List<dynamic> contactList = jsonDecode(contactsJson);
      for (final contactMap in contactList) {
        _teamProfiles.add(OperatorProfile.fromJson(contactMap));
      }
    }

    final chatHistoryJson = prefs.getString('c2_chat_history');
    if (chatHistoryJson != null) {
      final List<dynamic> msgList = jsonDecode(chatHistoryJson);
      _globalMessages.clear();
      for (final m in msgList) {
        _globalMessages.add(C2Message.fromEnvelopeJson(m, _myProfile.id));
      }
    }

    if (loadedKeys == null) {
      await prefs.setString('c2_my_profile', jsonEncode(_myProfile.toJson()));
      await prefs.setString('c2_keys', jsonEncode(keys));
      _addEventLog('OPERATOR INITIALIZED', 'Identity initialized for ${_myProfile.callsign} (${_myProfile.id})', EventSeverity.info);
    }

    _cryptoEngine = E2EEEngine(
      myPrivateKey: keys['privateKey']!,
      myPublicKey: keys['publicKey']!,
    );

    _mlsGroupEngine = MLSGroupEngine(
      groupId: 'grp-strike-team-alpha',
      groupName: 'STRIKE TEAM ALPHA',
      groupSecret: 'mls_group_secret_epoch_1_pass',
      memberPublicKeys: _teamProfiles.map((p) => p.publicKey).toList(),
    );

    _meshClient = MeshClient(
      myOperatorId: _myProfile.id,
      seedNodeUrls: candidateMeshNodes,
    );

    _p2pMeshEngine = P2PMeshEngine(
      myOperatorId: _myProfile.id,
      p2pPort: 9090,
    );

    _telemetryService = TelemetryService(
      myOperatorId: _myProfile.id,
      meshClient: _meshClient,
      p2pMeshEngine: _p2pMeshEngine,
      mlsGroupEngine: _mlsGroupEngine,
    );

    PttAudioService.initializeGlobalListener(
      meshClient: _meshClient,
      p2pMeshEngine: _p2pMeshEngine,
      myOperatorId: _myProfile.id,
    );

    _meshClient.connectionState.listen((connected) {
      if (!mounted) return;
      setState(() {
        _isMeshConnected = connected;
        if (connected) {
          _activeNodeId = _meshClient.activeNodeId ?? 'mesh-node';
        }
      });
    });

    void processIncomingMessage(C2Message msg) {
      if (!mounted) return;

      if (msg.type == MessageType.sosAlert) {
        final decrypted = _mlsGroupEngine.decryptGroupMessage(msg.encryptedBody);
        if (decrypted.startsWith('[GROUP DECRYPTION ERROR')) {
          debugPrint('[SECURITY ALERT] Rejected SOS beacon from unpaired device!');
          return;
        }
        final senderCallsign = msg.senderId.startsWith('op-')
            ? _teamProfiles.firstWhere((p) => p.id == msg.senderId, orElse: () => _myProfile).callsign
            : msg.senderId;

        setState(() {
          _activeSosOperatorCallsign = senderCallsign;
        });
        _addEventLog('EMERGENCY SOS', 'Distress beacon received from $senderCallsign', EventSeverity.alert);
        _showInAppNotification(
          title: 'ALERT: EMERGENCY SOS',
          message: 'Distress signal received from $senderCallsign',
          color: Colors.red,
        );
      } else if (msg.type == MessageType.callSignaling) {
        if (msg.encryptedBody.contains('CALL_END')) {
          _addEventLog('CALL ENDED', 'Voice/Video call ended by peer', EventSeverity.info);
          setState(() {
            _isCallActive = false;
            _activeCallPeer = null;
          });
        } else if (msg.encryptedBody.contains('CALL_ACCEPT')) {
          _addEventLog('CALL ACCEPTED', 'Peer accepted voice/video call', EventSeverity.info);
          setState(() {
            _isCallActive = true;
            _currentIndex = 2;
          });
        } else if (msg.encryptedBody.contains('CALL_INITIATE_VOICE') || msg.encryptedBody.contains('CALL_INITIATE_VIDEO')) {
          if (msg.recipientId == _myProfile.id) {
            final peer = _teamProfiles.firstWhere(
              (p) => p.id == msg.senderId || p.callsign == msg.senderId,
              orElse: () => OperatorProfile(
                id: msg.senderId,
                callsign: msg.senderId,
                name: 'Incoming Call',
                role: OperatorRole.operator,
                avatarBase64: '',
                publicKey: '',
                lastSeen: DateTime.now(),
                isOnline: true,
              ),
            );

            _addEventLog('INCOMING CALL', 'Incoming call from ${peer.callsign}', EventSeverity.info);
            _showIncomingCallAlert(peer, isVideo: msg.encryptedBody.contains('VIDEO'));
          }
        } else if ((msg.encryptedBody.contains('PTT_AUDIO_CHUNK') || msg.encryptedBody.contains('CALL_VOICE_STREAM')) && msg.senderId != _myProfile.id) {
          // Process audio chunk / voice stream quietly without spawning UI notification banners
        } else if (msg.encryptedBody.contains('PTT_START') && msg.senderId != _myProfile.id) {
          final senderPeer = _teamProfiles.firstWhere(
            (p) => p.id == msg.senderId || p.callsign == msg.senderId,
            orElse: () => OperatorProfile(
              id: msg.senderId,
              callsign: msg.senderId,
              name: 'Squad Member',
              role: OperatorRole.operator,
              avatarBase64: '',
              publicKey: '',
              lastSeen: DateTime.now(),
              isOnline: true,
            ),
          );

          _addEventLog('PTT AUDIO RECEIVED', 'Live PTT radio stream from ${senderPeer.callsign}', EventSeverity.info);
          _triggerAudibleAndHapticAlert();
          _showInAppNotification(
            title: '📻 PTT AUDIO TRANSMISSION FROM ${senderPeer.callsign}',
            message: 'Live voice radio stream active...',
            color: Colors.cyanAccent,
            onTap: () {
              setState(() {
                _currentIndex = 2;
              });
            },
          );
        }
      } else if (msg.type == MessageType.chat1to1 && msg.recipientId == _myProfile.id) {
        final targetPubKey = (msg.senderPublicKey != null && msg.senderPublicKey!.isNotEmpty)
            ? msg.senderPublicKey!
            : _teamProfiles.firstWhere(
                (p) => p.id == msg.senderId || p.callsign == msg.senderId,
                orElse: () => _myProfile,
              ).publicKey;

        final decrypted = _cryptoEngine.decryptPayload(msg.encryptedBody, targetPubKey);
        final decryptedMsg = msg.copyWith(
          decryptedText: decrypted,
          newStatus: MessageStatus.delivered,
        );

        _addGlobalMessage(decryptedMsg);
        _sendDeliveryReceipt(msg.id, msg.senderId);

        final senderPeer = _teamProfiles.firstWhere(
          (p) => p.id == msg.senderId || p.callsign == msg.senderId,
          orElse: () => OperatorProfile(
            id: msg.senderId,
            callsign: msg.senderId,
            name: 'Peer',
            role: OperatorRole.operator,
            avatarBase64: '',
            publicKey: targetPubKey,
            lastSeen: DateTime.now(),
            isOnline: true,
          ),
        );

        _addEventLog('E2EE TEXT RECEIVED', 'Message from ${senderPeer.callsign}: "$decrypted"', EventSeverity.info);

        _triggerAudibleAndHapticAlert();

        if (_currentIndex != 1) {
          _showInAppNotification(
            title: 'SECURE E2EE MESSAGE FROM ${senderPeer.callsign}',
            message: decrypted,
            color: Colors.cyanAccent,
            onTap: () {
              _sendReadReceipt(msg.id, msg.senderId);
              setState(() {
                _activeChatPeer = senderPeer;
                _activeChatSubTab = 0;
                _currentIndex = 1;
              });
            },
          );
        }
      } else if (msg.type == MessageType.chatGroup && msg.senderId != _myProfile.id) {
        final decrypted = _mlsGroupEngine.decryptGroupMessage(msg.encryptedBody);
        final decryptedMsg = msg.copyWith(
          decryptedText: decrypted,
          newStatus: MessageStatus.delivered,
        );

        _addGlobalMessage(decryptedMsg);
        _sendDeliveryReceipt(msg.id, msg.senderId);

        final senderPeer = _teamProfiles.firstWhere(
          (p) => p.id == msg.senderId || p.callsign == msg.senderId,
          orElse: () => OperatorProfile(
            id: msg.senderId,
            callsign: msg.senderId,
            name: 'Squad Member',
            role: OperatorRole.operator,
            avatarBase64: '',
            publicKey: '',
            lastSeen: DateTime.now(),
            isOnline: true,
          ),
        );

        _addEventLog('GROUP MLS TEXT RECEIVED', 'Group message from ${senderPeer.callsign}: "$decrypted"', EventSeverity.info);

        _triggerAudibleAndHapticAlert();

        if (_currentIndex != 1) {
          _showInAppNotification(
            title: 'SQUAD GROUP MESSAGE FROM ${senderPeer.callsign}',
            message: decrypted,
            color: Colors.cyanAccent,
            onTap: () {
              setState(() {
                _activeChatSubTab = 1;
                _currentIndex = 1;
              });
            },
          );
        }
      } else if (msg.type == MessageType.broadcast) {
        if (msg.encryptedBody.contains('DELIVERY_ACK')) {
          try {
            final Map<String, dynamic> data = jsonDecode(msg.encryptedBody);
            final msgId = data['message_id'];
            _updateMessageStatus(msgId, MessageStatus.delivered);
          } catch (_) {}
        } else if (msg.encryptedBody.contains('READ_ACK')) {
          try {
            final Map<String, dynamic> data = jsonDecode(msg.encryptedBody);
            final msgId = data['message_id'];
            _updateMessageStatus(msgId, MessageStatus.read);
          } catch (_) {}
        } else if (msg.encryptedBody.contains('UNPAIR_AND_PURGE')) {
          try {
            final Map<String, dynamic> data = jsonDecode(msg.encryptedBody);
            final purgedOpId = data['operator_id'] ?? msg.senderId;
            final purgedCallsign = data['callsign'] ?? msg.senderId;

            _handleIncomingRemoteUnpair(purgedOpId, purgedCallsign);
          } catch (_) {}
        } else if (msg.encryptedBody.contains('PAIR_ACK')) {
          try {
            final Map<String, dynamic> data = jsonDecode(msg.encryptedBody);
            final tokenId = data['token_id'] ?? '';
            final peerProfile = OperatorProfile(
              id: data['operator_id'] ?? msg.senderId,
              callsign: data['callsign'] ?? 'OPERATOR',
              name: data['name'] ?? 'Squad Member',
              role: OperatorRole.operator,
              avatarBase64: '',
              publicKey: data['public_key'] ?? '',
              lastSeen: DateTime.now(),
              isOnline: true,
            );

            // If already paired with this operator, ignore duplicate ACK
            final isAlreadyPaired = _teamProfiles.any((p) => p.id == peerProfile.id);
            if (isAlreadyPaired) {
              return;
            }

            // Complete pairing locally without re-transmitting
            _addContactDirectly(peerProfile, tokenId: tokenId, sendPairRequest: false);
          } catch (_) {}
        } else if (msg.encryptedBody.contains('PAIR_REQUEST')) {
          try {
            final Map<String, dynamic> data = jsonDecode(msg.encryptedBody);
            final tokenId = data['token_id'] ?? '';
            final applicant = OperatorProfile(
              id: data['operator_id'] ?? msg.senderId,
              callsign: data['callsign'] ?? 'OPERATOR',
              name: data['name'] ?? 'Squad Member',
              role: OperatorRole.operator,
              avatarBase64: '',
              publicKey: data['public_key'] ?? '',
              lastSeen: DateTime.now(),
              isOnline: true,
            );

            if (applicant.id == _myProfile.id || msg.senderId == _myProfile.id) {
              return; // Ignore self-pairing requests
            }

            // If already paired with this operator or dialog active, ignore to prevent loops
            final isAlreadyPaired = _teamProfiles.any((p) => p.id == applicant.id);
            if (isAlreadyPaired || _activePairingDialogs.contains(applicant.id)) {
              return;
            }

            if (tokenId.isNotEmpty && _consumedPairingTokens.contains(tokenId)) {
              _notifyTokenReuseSecurityAlert(applicant, tokenId);
            } else {
              _showPairingApprovalDialog(applicant, tokenId);
            }
          } catch (_) {}
        } else if (msg.senderId != _myProfile.id) {
          String decrypted = msg.encryptedBody;
          try {
            decrypted = _mlsGroupEngine.decryptGroupMessage(msg.encryptedBody);
          } catch (_) {}

          final decryptedMsg = msg.copyWith(
            decryptedText: decrypted,
            newStatus: MessageStatus.delivered,
          );

          _addGlobalMessage(decryptedMsg);
          _sendDeliveryReceipt(msg.id, msg.senderId);

          final senderPeer = _teamProfiles.firstWhere(
            (p) => p.id == msg.senderId || p.callsign == msg.senderId,
            orElse: () => OperatorProfile(
              id: msg.senderId,
              callsign: msg.senderId,
              name: 'Squad Member',
              role: OperatorRole.operator,
              avatarBase64: '',
              publicKey: '',
              lastSeen: DateTime.now(),
              isOnline: true,
            ),
          );

          _addEventLog('OPERATIONAL BROADCAST RECEIVED', 'Broadcast from ${senderPeer.callsign}: "$decrypted"', EventSeverity.info);

          _triggerAudibleAndHapticAlert();

          if (_currentIndex != 1) {
            _showInAppNotification(
              title: 'OPERATIONAL BROADCAST FROM ${senderPeer.callsign}',
              message: decrypted,
              color: Colors.amberAccent,
              onTap: () {
                setState(() {
                  _activeChatSubTab = 2;
                  _currentIndex = 1;
                });
              },
            );
          }
        }
      }
    }

    _meshClient.incomingMessages.listen(processIncomingMessage);
    _p2pMeshEngine.incomingP2PMessages.listen(processIncomingMessage);

    _p2pMeshEngine.discoveredPeers.listen((peers) {
      if (!mounted) return;
      setState(() {
        if (!_isMeshConnected && peers.isNotEmpty) {
          _activeNodeId = 'PURE P2P MESH (${peers.length} PEERS)';
        }
      });
    });

    _telemetryService.myTelemetry.listen((tele) {
      if (!mounted) return;
      setState(() {
        _myTelemetry = tele;
      });
    });

    _telemetryService.teamTelemetry.listen((teamMap) {
      if (!mounted) return;
      setState(() {
        _teamTelemetry = teamMap;
      });
    });

    _meshClient.start();
    _p2pMeshEngine.start();
    _telemetryService.startReporting();

    setState(() {
      _myProfileInitialized = true;
      _isLoading = false;
    });
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

  void _sendDeliveryReceipt(String messageId, String recipientId) {
    final ackPayload = {
      'action': 'DELIVERY_ACK',
      'message_id': messageId,
      'sender_id': _myProfile.id,
    };
    final ackMsg = C2Message(
      id: 'ack-del-${DateTime.now().millisecondsSinceEpoch}',
      type: MessageType.broadcast,
      senderId: _myProfile.id,
      recipientId: recipientId,
      encryptedBody: jsonEncode(ackPayload),
      timestamp: DateTime.now(),
    );
    _meshClient.sendMessage(ackMsg);
    _p2pMeshEngine.sendP2PDirectMessage(ackMsg);
  }

  void _sendReadReceipt(String messageId, String recipientId) {
    final ackPayload = {
      'action': 'READ_ACK',
      'message_id': messageId,
      'sender_id': _myProfile.id,
    };
    final ackMsg = C2Message(
      id: 'ack-read-${DateTime.now().millisecondsSinceEpoch}',
      type: MessageType.broadcast,
      senderId: _myProfile.id,
      recipientId: recipientId,
      encryptedBody: jsonEncode(ackPayload),
      timestamp: DateTime.now(),
    );
    _meshClient.sendMessage(ackMsg);
    _p2pMeshEngine.sendP2PDirectMessage(ackMsg);
  }

  void _updateMessageStatus(String messageId, MessageStatus newStatus) {
    setState(() {
      final index = _globalMessages.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        _globalMessages[index] = _globalMessages[index].copyWith(newStatus: newStatus);
      }
    });
  }

  // Called when local user clicks "UNPAIR & DELETE" on a contact
  Future<void> _removeContactInitiatedByMe(String targetOpId) async {
    final peer = _teamProfiles.firstWhere(
      (p) => p.id == targetOpId,
      orElse: () => OperatorProfile(
        id: targetOpId,
        callsign: targetOpId,
        name: 'Peer',
        role: OperatorRole.operator,
        avatarBase64: '',
        publicKey: '',
        lastSeen: DateTime.now(),
        isOnline: false,
      ),
    );

    // 1. Send targeted unpair signal to the recipient so their app unpairs us as well
    final unpairPayload = {
      'action': 'UNPAIR_AND_PURGE',
      'operator_id': _myProfile.id,
      'callsign': _myProfile.callsign,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    final unpairMsg = C2Message(
      id: 'unpair-${DateTime.now().millisecondsSinceEpoch}',
      type: MessageType.broadcast,
      senderId: _myProfile.id,
      senderPublicKey: _myProfile.publicKey,
      recipientId: targetOpId,
      encryptedBody: jsonEncode(unpairPayload),
      timestamp: DateTime.now(),
      isMe: true,
    );
    _meshClient.sendMessage(unpairMsg);
    _p2pMeshEngine.sendP2PDirectMessage(unpairMsg);

    // 2. Remove locally
    _performLocalContactRemoval(targetOpId, peer.callsign);
    _addEventLog('CONTACT UNPAIRED', 'Unpaired and deleted contact ${peer.callsign} (${peer.id})', EventSeverity.warning);
  }

  // Called when a remote unpair signal arrives from another peer
  void _handleIncomingRemoteUnpair(String opId, String callsign) {
    _performLocalContactRemoval(opId, callsign);
    _addEventLog('REMOTE UNPAIR RECEIVED', 'Operator $callsign un-paired from your squad directory', EventSeverity.warning);
    
    SystemSound.play(SystemSoundType.alert);
    _showInAppNotification(
      title: '⚠️ OPERATOR UNPAIRED & REMOVED',
      message: 'Operator $callsign un-paired from squad directory. Contact removed.',
      color: Colors.amberAccent,
    );
  }

  Future<void> _performLocalContactRemoval(String opId, String callsign) async {
    setState(() {
      _teamProfiles.removeWhere((p) => p.id == opId || p.callsign == callsign);
      _teamTelemetry.remove(opId);
      _mlsGroupEngine.memberPublicKeys.removeWhere((k) => k == opId);
      _mlsGroupEngine.ratchetEpoch();
    });

    final prefs = await SharedPreferences.getInstance();
    final serializableList = _teamProfiles
        .where((p) => p.id != _myProfile.id)
        .map((p) => p.toJson())
        .toList();
    await prefs.setString('c2_contacts', jsonEncode(serializableList));
  }

  void _broadcastUnpairAndPurgeSignal() {
    final purgePayload = {
      'action': 'UNPAIR_AND_PURGE',
      'operator_id': _myProfile.id,
      'callsign': _myProfile.callsign,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    final purgeMsg = C2Message(
      id: 'purge-${DateTime.now().millisecondsSinceEpoch}',
      type: MessageType.broadcast,
      senderId: _myProfile.id,
      senderPublicKey: _myProfile.publicKey,
      encryptedBody: jsonEncode(purgePayload),
      timestamp: DateTime.now(),
      isMe: true,
    );
    _meshClient.sendMessage(purgeMsg);
    _p2pMeshEngine.sendP2PDirectMessage(purgeMsg);
  }

  Future<void> _addGlobalMessage(C2Message msg) async {
    if (_globalMessages.any((m) => m.id == msg.id)) return;
    setState(() {
      _globalMessages.add(msg);
    });

    final prefs = await SharedPreferences.getInstance();
    final serializable = _globalMessages.map((m) => m.toEnvelopeJson()).toList();
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
                color: Colors.amber.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.amberAccent.withOpacity(0.4)),
              ),
              child: const Text(
                '⚠️ WARNING: This pairing token was previously consumed. Reusing pairing codes can expose your E2EE identity keys to unauthorized devices on the mesh network. Do you trust this operator and wish to accept pairing anyway?',
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

  Future<void> _forceAddContact(OperatorProfile newProfile, {String tokenId = ''}) async {
    if (tokenId.isNotEmpty) {
      _consumedPairingTokens.add(tokenId);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('c2_consumed_pairing_tokens', jsonEncode(_consumedPairingTokens.toList()));
    }

    final isAlreadyPaired = _teamProfiles.any((p) => p.id == newProfile.id);

    setState(() {
      if (!isAlreadyPaired) {
        _teamProfiles.add(newProfile);
        _mlsGroupEngine.memberPublicKeys.add(newProfile.publicKey);
        _mlsGroupEngine.ratchetEpoch();
      }
    });

    _addEventLog('PAIRING APPROVED (OVERRIDE)', 'Overrode security warning and paired with ${newProfile.callsign}', EventSeverity.warning);

    final prefs = await SharedPreferences.getInstance();
    final serializableList = _teamProfiles
        .where((p) => p.id != _myProfile.id)
        .map((p) => p.toJson())
        .toList();
    await prefs.setString('c2_contacts', jsonEncode(serializableList));

    if (!isAlreadyPaired) {
      final requestPayload = {
        'action': 'PAIR_ACK',
        'token_id': tokenId,
        'operator_id': _myProfile.id,
        'callsign': _myProfile.callsign,
        'name': _myProfile.name,
        'public_key': _myProfile.publicKey,
      };
      final requestMsg = C2Message(
        id: 'pair-ack-${DateTime.now().millisecondsSinceEpoch}',
        type: MessageType.broadcast,
        senderId: _myProfile.id,
        senderPublicKey: _myProfile.publicKey,
        recipientId: newProfile.id,
        encryptedBody: jsonEncode(requestPayload),
        timestamp: DateTime.now(),
        isMe: true,
      );
      _meshClient.sendMessage(requestMsg);
      _p2pMeshEngine.sendP2PDirectMessage(requestMsg);
    }

    _showInAppNotification(
      title: 'PAIRING COMPLETED',
      message: 'Operator ${newProfile.callsign} added to squad directory.',
      color: C2Colors.emeraldAccent,
    );
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
            Text('Operator Name: ${applicant.name}', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Operator ID: ${applicant.id}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
            const SizedBox(height: 12),
            const Text(
              'Do you approve adding this operator to your E2EE secure squad directory and exchanging situational map telemetry?',
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
              _addContactDirectly(applicant, tokenId: tokenId, sendPairRequest: false);

              // Transmit PAIR_ACK back to applicant so applicant completes pairing
              final ackPayload = {
                'action': 'PAIR_ACK',
                'token_id': tokenId,
                'operator_id': _myProfile.id,
                'callsign': _myProfile.callsign,
                'name': _myProfile.name,
                'public_key': _myProfile.publicKey,
              };
              final ackMsg = C2Message(
                id: 'pair-ack-${DateTime.now().millisecondsSinceEpoch}',
                type: MessageType.broadcast,
                senderId: _myProfile.id,
                senderPublicKey: _myProfile.publicKey,
                recipientId: applicant.id,
                encryptedBody: jsonEncode(ackPayload),
                timestamp: DateTime.now(),
                isMe: true,
              );
              _meshClient.sendMessage(ackMsg);
              _p2pMeshEngine.sendP2PDirectMessage(ackMsg);
            },
            child: const Text('APPROVE & PAIR', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ).then((_) => _activePairingDialogs.remove(applicant.id));
  }

  void _showIncomingCallAlert(OperatorProfile peer, {required bool isVideo}) {
    _triggerAudibleAndHapticAlert();
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: isVideo ? Colors.cyanAccent : C2Colors.emeraldAccent, width: 2),
              boxShadow: [
                BoxShadow(
                  color: (isVideo ? Colors.cyanAccent : C2Colors.emeraldAccent).withOpacity(0.4),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: C2Colors.slateCard,
                  child: Text(
                    peer.callsign.substring(0, peer.callsign.length >= 2 ? 2 : peer.callsign.length),
                    style: const TextStyle(color: Colors.cyanAccent, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'INCOMING ${isVideo ? "VIDEO" : "VOICE"} CALL',
                  style: TextStyle(
                    color: isVideo ? Colors.cyanAccent : C2Colors.emeraldAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  peer.callsign,
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                Text(
                  peer.name,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.call_end),
                        label: const Text('DECLINE', style: TextStyle(fontWeight: FontWeight.bold)),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: C2Colors.emeraldAccent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.call),
                        label: const Text('ANSWER', style: TextStyle(fontWeight: FontWeight.bold)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _acceptCallSignal(peer);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _acceptCallSignal(OperatorProfile peer) {
    final acceptMsg = C2Message(
      id: 'call-accept-${DateTime.now().millisecondsSinceEpoch}',
      type: MessageType.callSignaling,
      senderId: _myProfile.id,
      senderPublicKey: _myProfile.publicKey,
      recipientId: peer.id,
      encryptedBody: 'CALL_ACCEPT',
      timestamp: DateTime.now(),
      isMe: true,
    );
    _meshClient.sendMessage(acceptMsg);
    _p2pMeshEngine.sendP2PDirectMessage(acceptMsg);

    setState(() {
      _activeCallPeer = peer;
      _isCallActive = true;
      _currentIndex = 2;
    });
  }

  Future<void> _addContactDirectly(OperatorProfile newProfile, {String tokenId = '', bool sendPairRequest = true}) async {
    if (newProfile.id == _myProfile.id) {
      return; // Cannot pair with self
    }

    final isAlreadyPaired = _teamProfiles.any((p) => p.id == newProfile.id);
    if (isAlreadyPaired) {
      _showInAppNotification(
        title: 'ALREADY PAIRED',
        message: 'Operator ${newProfile.callsign} is already in your squad directory.',
        color: Colors.cyanAccent,
      );
      return;
    }

    // Only check consumed tokens when initiating a NEW pair request!
    // Response handshakes (sendPairRequest == false) MUST NOT trigger token reuse security warnings.
    if (sendPairRequest && tokenId.isNotEmpty && _consumedPairingTokens.contains(tokenId)) {
      _notifyTokenReuseSecurityAlert(newProfile, tokenId);
      return;
    }

    if (tokenId.isNotEmpty) {
      _consumedPairingTokens.add(tokenId);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('c2_consumed_pairing_tokens', jsonEncode(_consumedPairingTokens.toList()));
    }

    setState(() {
      final exists = _teamProfiles.any((p) => p.id == newProfile.id);
      if (!exists) {
        _teamProfiles.add(newProfile);
        _mlsGroupEngine.memberPublicKeys.add(newProfile.publicKey);
        _mlsGroupEngine.ratchetEpoch();
      }
    });

    _addEventLog('PAIRING COMPLETED', 'Paired with operator ${newProfile.callsign} (${newProfile.name})', EventSeverity.info);

    final prefs = await SharedPreferences.getInstance();
    final serializableList = _teamProfiles
        .where((p) => p.id != _myProfile.id)
        .map((p) => p.toJson())
        .toList();
    await prefs.setString('c2_contacts', jsonEncode(serializableList));

    if (sendPairRequest) {
      final requestPayload = {
        'action': 'PAIR_REQUEST',
        'token_id': tokenId,
        'operator_id': _myProfile.id,
        'callsign': _myProfile.callsign,
        'name': _myProfile.name,
        'public_key': _myProfile.publicKey,
      };
      final requestMsg = C2Message(
        id: 'pair-${DateTime.now().millisecondsSinceEpoch}',
        type: MessageType.broadcast,
        senderId: _myProfile.id,
        senderPublicKey: _myProfile.publicKey,
        recipientId: newProfile.id,
        encryptedBody: jsonEncode(requestPayload),
        timestamp: DateTime.now(),
        isMe: true,
      );
      _meshClient.sendMessage(requestMsg);
      _p2pMeshEngine.sendP2PDirectMessage(requestMsg);
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
              final rawSos = 'EMERGENCY_SOS_SIGNAL_${_myProfile.callsign}';
              final encryptedBody = _mlsGroupEngine.encryptGroupMessage(rawSos);
              final sosMsg = C2Message(
                id: 'sos-${DateTime.now().millisecondsSinceEpoch}',
                type: MessageType.sosAlert,
                senderId: _myProfile.id,
                senderPublicKey: _myProfile.publicKey,
                encryptedBody: encryptedBody,
                timestamp: DateTime.now(),
                isMe: true,
              );
              _meshClient.sendMessage(sosMsg);
              _p2pMeshEngine.sendP2PDirectMessage(sosMsg);

              setState(() {
                _activeSosOperatorCallsign = _myProfile.callsign;
              });

              _addEventLog('EMERGENCY SOS BROADCAST', 'SOS distress beacon broadcast to squad', EventSeverity.alert);

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
    if (_myProfileInitialized) {
      _telemetryService.stopReporting();
      _p2pMeshEngine.stop();
      _meshClient.stop();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        onStartVoiceCall: (peer) {
          setState(() {
            _currentIndex = 2;
          });
        },
        onStartVideoCall: (peer) {
          setState(() {
            _currentIndex = 2;
          });
        },
        onOpenChat: (peer) {
          setState(() {
            _activeChatPeer = peer;
            _currentIndex = 1;
          });
        },
      ),
      ChatView(
        myProfile: _myProfile,
        teamProfiles: _teamProfiles,
        globalMessages: _globalMessages,
        activePeer: _activeChatPeer,
        initialSubTabIndex: _activeChatSubTab,
        meshClient: _meshClient,
        p2pMeshEngine: _p2pMeshEngine,
        cryptoEngine: _cryptoEngine,
        mlsGroupEngine: _mlsGroupEngine,
        onMessageSent: (msg) {
          _addGlobalMessage(msg);
        },
        onUpdateStatus: (msgId, status) {
          _updateMessageStatus(msgId, status);
        },
      ),
      CallView(
        myProfile: _myProfile,
        teamProfiles: _teamProfiles,
        activePeer: _activeCallPeer,
        isCallActive: _isCallActive,
        onCallEnded: () {
          setState(() {
            _isCallActive = false;
            _activeCallPeer = null;
          });
        },
        meshClient: _meshClient,
        p2pMeshEngine: _p2pMeshEngine,
      ),
      _buildTeamTelemetryDashboard(),
      QrPairingView(
        myProfile: _myProfile,
        meshNodeUrls: candidateMeshNodes,
        onContactAdded: (peer, tokenId) => _addContactDirectly(peer, tokenId: tokenId, sendPairRequest: true),
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
          _broadcastUnpairAndPurgeSignal();
          final prefs = await SharedPreferences.getInstance();
          await prefs.clear();
          setState(() {
            _myProfileInitialized = false;
            _globalMessages.clear();
            _eventLogs.clear();
            _consumedPairingTokens.clear();
            _teamProfiles.clear();
          });
        },
      ),
    ];

    return Scaffold(
      body: pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        selectedItemColor: Colors.cyanAccent,
        unselectedItemColor: Colors.white54,
        backgroundColor: const Color(0xFF1E293B),
        type: BottomNavigationBarType.fixed,
        onTap: (index) {
          if (index == 6) {
            _triggerSosEmergency();
          } else {
            setState(() {
              _currentIndex = index;
            });
          }
        },
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.map_outlined),
            activeIcon: Icon(Icons.map),
            label: '3D Map',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            activeIcon: Icon(Icons.chat_bubble),
            label: 'Comms',
          ),
          BottomNavigationBarItem(
            icon: ValueListenableBuilder<int>(
              valueListenable: PttAudioService.clipNotifier,
              builder: (context, count, child) {
                final unreadClips = PttAudioService.globalVoiceClips.where((c) => !c.isPlayed).length;
                if (unreadClips == 0) {
                  return const Icon(Icons.mic_none);
                }
                return Badge(
                  label: Text('$unreadClips', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                  backgroundColor: Colors.amberAccent,
                  textColor: Colors.black,
                  child: const Icon(Icons.mic_none, color: Colors.amberAccent),
                );
              },
            ),
            activeIcon: ValueListenableBuilder<int>(
              valueListenable: PttAudioService.clipNotifier,
              builder: (context, count, child) {
                final unreadClips = PttAudioService.globalVoiceClips.where((c) => !c.isPlayed).length;
                if (unreadClips == 0) {
                  return const Icon(Icons.mic);
                }
                return Badge(
                  label: Text('$unreadClips', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                  backgroundColor: Colors.amberAccent,
                  textColor: Colors.black,
                  child: const Icon(Icons.mic, color: Colors.cyanAccent),
                );
              },
            ),
            label: 'PTT/Calls',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.phone_android),
            activeIcon: Icon(Icons.phone_android),
            label: 'Telemetry',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.qr_code_2),
            activeIcon: Icon(Icons.qr_code_2),
            label: 'Pairing',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
          BottomNavigationBarItem(
            icon: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.warning, color: Colors.white, size: 14),
            ),
            label: 'SOS',
          ),
        ],
      ),
    );
  }

  Widget _buildTeamTelemetryDashboard() {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Row(
          children: [
            Icon(Icons.phone_android, color: Colors.cyanAccent, size: 20),
            SizedBox(width: 8),
            Text(
              'TEAM DEVICE TELEMETRY & STATS',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _teamProfiles.length,
        itemBuilder: (context, index) {
          final profile = _teamProfiles[index];
          final tele = profile.id == _myProfile.id
              ? _myTelemetry
              : _teamTelemetry[profile.id];

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: tele != null && !tele.isStale
                    ? C2Colors.emeraldAccent.withOpacity(0.5)
                    : Colors.amberAccent.withOpacity(0.5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: const Color(0xFF0F172A),
                          child: Text(
                            profile.callsign.substring(0, 2),
                            style: const TextStyle(
                                color: Colors.cyanAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${profile.callsign} (${profile.name})',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13),
                            ),
                            Text(
                              profile.role.name.toUpperCase(),
                              style: const TextStyle(
                                  color: Colors.cyanAccent, fontSize: 9),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: tele != null && !tele.isStale
                            ? C2Colors.emeraldAccent.withOpacity(0.2)
                            : Colors.amber.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        tele != null && !tele.isStale
                            ? 'LIVE TELEMETRY'
                            : 'STALE SIGNAL',
                        style: TextStyle(
                          color: tele != null && !tele.isStale
                              ? C2Colors.emeraldAccent
                              : Colors.amberAccent,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 16),
                if (tele != null) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildStatTile(
                        icon: Icons.battery_charging_full,
                        label: 'BATTERY',
                        value: '${tele.batteryLevel}%',
                        color: tele.batteryLevel > 20
                            ? C2Colors.emeraldAccent
                            : Colors.redAccent,
                      ),
                      _buildStatTile(
                        icon: Icons.wifi,
                        label: 'NET TYPE',
                        value: tele.networkType.name.toUpperCase(),
                        color: Colors.cyanAccent,
                      ),
                      _buildStatTile(
                        icon: Icons.signal_cellular_alt,
                        label: 'CELL SIGNAL',
                        value: '${tele.cellularSignalBars}/4 BARS',
                        color: Colors.amberAccent,
                      ),
                      _buildStatTile(
                        icon: Icons.router,
                        label: 'WI-FI SSID',
                        value: tele.wifiSSID,
                        color: Colors.purpleAccent,
                      ),
                    ],
                  ),
                ] else ...[
                  const Text('No telemetry frames received yet.',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatTile({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(
                color: Colors.white38,
                fontSize: 8,
                fontWeight: FontWeight.bold)),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold)),
      ],
    );
  }
}
