import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import '../models/telemetry.dart';
import '../models/c2_message.dart';
import '../services/mesh_client.dart';
import '../services/p2p_mesh_engine.dart';

class TelemetryService {
  final String myOperatorId;
  final MeshClient meshClient;
  final P2PMeshEngine? p2pMeshEngine;

  // Real Hardware Instances
  final Battery _battery = Battery();
  final Connectivity _connectivity = Connectivity();

  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // Current Hardware State
  double _currentLat = 0.0;
  double _currentLng = 0.0;
  double _currentAlt = 0.0;
  double _currentSpeed = 0.0;
  double _currentHeading = 0.0;
  int _batteryLevel = 100;
  bool _isCharging = false;
  NetworkType _netType = NetworkType.offline;
  String _wifiSSID = 'WIFI_LAN';
  int _cellularSignal = 3;

  final List<Telemetry> _offlineBuffer = [];

  final StreamController<Telemetry> _myTelemetryController =
      StreamController<Telemetry>.broadcast();
  final StreamController<Map<String, Telemetry>> _teamTelemetryController =
      StreamController<Map<String, Telemetry>>.broadcast();

  final Map<String, Telemetry> _teamLatestTelemetry = {};
  final Map<String, List<Telemetry>> _teamBreadcrumbs = {};

  Stream<Telemetry> get myTelemetry => _myTelemetryController.stream;
  Stream<Map<String, Telemetry>> get teamTelemetry =>
      _teamTelemetryController.stream;

  Map<String, Telemetry> get teamLatest => _teamLatestTelemetry;
  Map<String, List<Telemetry>> get teamBreadcrumbs => _teamBreadcrumbs;

  TelemetryService({
    required this.myOperatorId,
    required this.meshClient,
    this.p2pMeshEngine,
  }) {
    void handleIncomingTelemetry(C2Message msg) {
      if (msg.type == MessageType.telemetry) {
        try {
          final Map<String, dynamic> data = jsonDecode(msg.encryptedBody);
          final tele = Telemetry.fromJson(data);
          if (tele.operatorId.isNotEmpty && tele.latitude != 0.0) {
            _recordTeamTelemetry(tele);
          }
        } catch (_) {}
      }
    }

    // Listen to incoming network telemetry envelopes from relay and P2P mesh
    meshClient.incomingMessages.listen(handleIncomingTelemetry);
    p2pMeshEngine?.incomingP2PMessages.listen(handleIncomingTelemetry);

    // Initialize connectivity listener
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((results) {
      if (results.isEmpty) {
        _netType = NetworkType.offline;
        return;
      }
      final primary = results.first;
      if (primary == ConnectivityResult.wifi) {
        _netType = NetworkType.wifi;
      } else if (primary == ConnectivityResult.mobile) {
        _netType = NetworkType.cellular;
      } else {
        _netType = NetworkType.offline;
      }
    });
  }

  Timer? _heartbeatTimer;
  DateTime? _lastTelemetrySentTime;

  /// Dynamic power-aware heartbeat interval (15 to 30 mins)
  Duration get _heartbeatInterval {
    if (_isCharging || _batteryLevel > 50) {
      return const Duration(minutes: 15);
    } else if (_batteryLevel >= 20) {
      return const Duration(minutes: 20);
    } else {
      return const Duration(minutes: 30);
    }
  }

  /// Request permissions and start live hardware tracking
  Future<void> startReporting() async {
    // 1. Request location permissions
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) {
      // 2. IMMEDIATE PUSH ON APP START
      try {
        Position? initialPos = await Geolocator.getLastKnownPosition();
        initialPos ??= await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 5),
          ),
        );
        if (initialPos != null) {
          _currentLat = initialPos.latitude;
          _currentLng = initialPos.longitude;
          _currentAlt = initialPos.altitude;
          _currentSpeed = initialPos.speed;
          _sendLatestTelemetry(); // Immediate startup telemetry broadcast
        }
      } catch (e) {
        debugPrint('[TELEMETRY_SERVICE] Initial startup GPS push error: $e');
      }

      // 3. Movement GPS Stream with 3-meter distance filter
      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 3, // 3-meter movement filter
        ),
      ).listen((Position position) {
        _currentLat = position.latitude;
        _currentLng = position.longitude;
        _currentAlt = position.altitude;
        _currentSpeed = position.speed;
        _sendLatestTelemetry();
      });
    }

    // 4. Subscribe to Compass Stream
    _compassSubscription = FlutterCompass.events?.listen((CompassEvent event) {
      final direction = event.heading;
      if (direction != null) {
        _currentHeading = direction;
      }
    });

    // 5. Power-Aware Heartbeat Timer (checks every 30 seconds)
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        _batteryLevel = await _battery.batteryLevel;
        final state = await _battery.onBatteryStateChanged.first;
        _isCharging = state == BatteryState.charging;
      } catch (_) {}

      final now = DateTime.now();
      final timeSinceLastSent = _lastTelemetrySentTime == null
          ? Duration.zero
          : now.difference(_lastTelemetrySentTime!);

      // Force push if heartbeat interval elapsed or initial location missing
      if (_lastTelemetrySentTime == null || timeSinceLastSent >= _heartbeatInterval || _currentLat == 0.0) {
        debugPrint('[TELEMETRY_SERVICE] Heartbeat push triggered (interval: ${_heartbeatInterval.inMinutes}m, battery: $_batteryLevel%, charging: $_isCharging)');
        try {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              timeLimit: Duration(seconds: 4),
            ),
          );
          _currentLat = pos.latitude;
          _currentLng = pos.longitude;
          _currentAlt = pos.altitude;
          _currentSpeed = pos.speed;
        } catch (_) {}

        _sendLatestTelemetry();
      }
    });
  }

  void stopReporting() {
    _positionSubscription?.cancel();
    _compassSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _heartbeatTimer?.cancel();
  }

  void _sendLatestTelemetry() {
    if (_currentLat == 0.0 || _currentLng == 0.0) {
      return; // Do not broadcast zero coordinates over network
    }

    _lastTelemetrySentTime = DateTime.now();

    final tele = Telemetry(
      operatorId: myOperatorId,
      latitude: _currentLat,
      longitude: _currentLng,
      altitude: _currentAlt,
      speed: _currentSpeed,
      heading: _currentHeading,
      accuracy: 3.0,
      batteryLevel: _batteryLevel,
      isCharging: _isCharging,
      networkType: _netType,
      cellularSignalBars: _cellularSignal,
      wifiSSID: _wifiSSID,
      timestamp: DateTime.now(),
    );

    _myTelemetryController.add(tele);
    _recordTeamTelemetry(tele);

    // Create telemetry broadcast envelope
    final envelope = C2Message(
      id: 'tele-${DateTime.now().millisecondsSinceEpoch}',
      type: MessageType.telemetry,
      senderId: myOperatorId,
      encryptedBody: jsonEncode(tele.toJson()),
      timestamp: DateTime.now(),
      isMe: true,
    );

    final sentMesh = meshClient.sendMessage(envelope);
    final sentP2P = p2pMeshEngine?.sendP2PDirectMessage(envelope) ?? false;
    final sent = sentMesh || sentP2P;

    if (!sent) {
      _offlineBuffer.add(tele);
      if (_offlineBuffer.length > 200) _offlineBuffer.removeAt(0);
    } else if (_offlineBuffer.isNotEmpty) {
      // Flush buffered offline telemetry
      for (final buffered in List<Telemetry>.from(_offlineBuffer)) {
        final offlineEnv = C2Message(
          id: 'tele-${buffered.timestamp.millisecondsSinceEpoch}',
          type: MessageType.telemetry,
          senderId: myOperatorId,
          encryptedBody: jsonEncode(buffered.toJson()),
          timestamp: buffered.timestamp,
          isMe: true,
        );
        final flushedMesh = meshClient.sendMessage(offlineEnv);
        final flushedP2P = p2pMeshEngine?.sendP2PDirectMessage(offlineEnv) ?? false;
        if (flushedMesh || flushedP2P) {
          _offlineBuffer.remove(buffered);
        }
      }
    }
  }

  void _recordTeamTelemetry(Telemetry tele) {
    _teamLatestTelemetry[tele.operatorId] = tele;
    
    // Maintain breadcrumb trail (max 50 past waypoints per operator)
    final history = _teamBreadcrumbs[tele.operatorId] ?? [];
    history.add(tele);
    if (history.length > 50) history.removeAt(0);
    _teamBreadcrumbs[tele.operatorId] = history;

    _teamTelemetryController.add(Map<String, Telemetry>.from(_teamLatestTelemetry));
  }
}
