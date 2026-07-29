import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import '../models/c2_message.dart';
import '../models/telemetry.dart';
import 'mesh_client.dart';
import 'p2p_mesh_engine.dart';
import 'secure_channel.dart';
import 'telemetry_cadence.dart';

class TelemetryService {
  static const _maxOfflineBuffer = 200;
  static const _maxBreadcrumbs = 50;

  /// How often the heartbeat re-evaluates conditions. The reporting interval
  /// itself comes from [_cadence] and changes as the operator does.
  static const _tickInterval = Duration(seconds: 10);

  final SecureChannel channel;
  final MeshClient meshClient;
  final P2PMeshEngine? p2pMeshEngine;

  final Battery _battery = Battery();
  final Connectivity _connectivity = Connectivity();

  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<BatteryState>? _batterySubscription;
  StreamSubscription<C2Message>? _meshSubscription;
  StreamSubscription<C2Message>? _p2pSubscription;

  double? _currentLat;
  double? _currentLng;
  double _currentAlt = 0.0;
  double _currentSpeed = 0.0;
  double _currentHeading = 0.0;
  double _currentAccuracy = 0.0;
  int _batteryLevel = 100;
  bool _isCharging = false;
  NetworkType _netType = NetworkType.offline;

  /// Decides the reporting interval from motion, power and link type.
  final TelemetryCadence _cadence = TelemetryCadence();

  MotionState get motionState => _cadence.motion;

  final List<Telemetry> _offlineBuffer = [];

  final _myTelemetryController = StreamController<Telemetry>.broadcast();
  final _teamTelemetryController = StreamController<Map<String, Telemetry>>.broadcast();
  final _rejectionController = StreamController<RejectedMessage>.broadcast();

  final Map<String, Telemetry> _teamLatestTelemetry = {};
  final Map<String, List<Telemetry>> _teamBreadcrumbs = {};

  Stream<Telemetry> get myTelemetry => _myTelemetryController.stream;
  Stream<Map<String, Telemetry>> get teamTelemetry => _teamTelemetryController.stream;
  Stream<RejectedMessage> get rejections => _rejectionController.stream;

  Map<String, Telemetry> get teamLatest => _teamLatestTelemetry;
  Map<String, List<Telemetry>> get teamBreadcrumbs => _teamBreadcrumbs;

  Timer? _heartbeatTimer;
  DateTime? _lastTelemetrySentTime;

  TelemetryService({
    required this.channel,
    required this.meshClient,
    this.p2pMeshEngine,
  }) {
    _meshSubscription = meshClient.incomingMessages.listen(_handleIncomingTelemetry);
    _p2pSubscription = p2pMeshEngine?.incomingP2PMessages.listen(_handleIncomingTelemetry);

    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((results) {
      if (results.isEmpty) {
        _netType = NetworkType.offline;
        return;
      }
      switch (results.first) {
        case ConnectivityResult.wifi:
          _netType = NetworkType.wifi;
        case ConnectivityResult.mobile:
          _netType = NetworkType.cellular;
        default:
          _netType = NetworkType.offline;
      }
    });
  }

  Future<void> _handleIncomingTelemetry(C2Message msg) async {
    if (msg.type != MessageType.telemetry) return;

    // Verified and decrypted centrally: a position only reaches the map if it
    // was signed by a paired contact whose ID matches its identity key.
    final result = await channel.open(msg);
    if (result is RejectedMessage) {
      if (!_rejectionController.isClosed) _rejectionController.add(result);
      return;
    }

    final opened = result as OpenedMessage;
    try {
      final data = jsonDecode(opened.plaintext) as Map<String, dynamic>;
      final parsed = Telemetry.fromJson(data);

      // The envelope's proven sender wins over whatever the payload claims, so
      // a paired contact cannot report a position on somebody else's behalf.
      final tele = parsed.copyWith(operatorId: opened.envelope.senderId);
      if (!_isPlausiblePosition(tele)) {
        debugPrint('[TELEMETRY] Discarded out-of-range position from ${tele.operatorId}');
        return;
      }

      _recordTeamTelemetry(tele);
    } catch (e) {
      debugPrint('[TELEMETRY] Malformed payload from ${msg.senderId}: $e');
    }
  }

  static bool _isPlausiblePosition(Telemetry t) =>
      t.latitude.abs() <= 90.0 &&
      t.longitude.abs() <= 180.0 &&
      !(t.latitude == 0.0 && t.longitude == 0.0);

  /// Current reporting interval, from the adaptive policy.
  ///
  /// Replaces a battery-only heartbeat that ran between 15 and 30 minutes
  /// regardless of what the operator was doing — far too slow to follow anyone
  /// who was actually moving.
  Duration get _reportInterval => _cadence.intervalFor(
        batteryLevel: _batteryLevel,
        isCharging: _isCharging,
        network: _netType,
      );

  Future<void> startReporting() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission != LocationPermission.always &&
        permission != LocationPermission.whileInUse) {
      debugPrint('[TELEMETRY] Location permission is $permission — this device '
          'will not report a position to the squad.');
    }

    if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
      try {
        var initialPos = await Geolocator.getLastKnownPosition();
        initialPos ??= await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 5),
          ),
        );
        _applyPosition(initialPos);
        await _sendLatestTelemetry(force: true);
      } catch (e) {
        debugPrint('[TELEMETRY] Initial GPS fix failed: $e');
      }

      _subscribePositionStream();
    }

    // flutter_compass ships no desktop implementation, and its platform stream
    // throws MissingPluginException on listen rather than returning null. Guard
    // by platform and handle the error, so a headless heading simply stays at 0
    // instead of surfacing an unhandled exception at every startup.
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        _compassSubscription = FlutterCompass.events?.listen(
          (event) {
            final heading = event.heading;
            if (heading != null) _currentHeading = heading;
          },
          onError: (Object e) => debugPrint('[TELEMETRY] Compass unavailable: $e'),
          cancelOnError: true,
        );
      } catch (e) {
        debugPrint('[TELEMETRY] Compass unavailable: $e');
      }
    }

    // Track charge state from the event stream rather than awaiting `.first`
    // inside the heartbeat: that waits for the *next* transition, which on a
    // stationary charge state never arrives, leaking a subscription per tick.
    try {
      _batteryLevel = await _battery.batteryLevel;
      _isCharging = (await _battery.batteryState) == BatteryState.charging;
    } catch (_) {}
    _batterySubscription = _battery.onBatteryStateChanged.listen((state) {
      _isCharging = state == BatteryState.charging;
    });

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_tickInterval, (_) => _onHeartbeat());
  }

  /// (Re)subscribes to the position stream with settings matched to how the
  /// operator is currently moving.
  ///
  /// A stationary device does not need high-accuracy fixes every few metres;
  /// a moving one does. This governs how often the GPS subsystem wakes at all,
  /// which is the larger share of the power cost.
  void _subscribePositionStream() {
    _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: _cadence.wantsHighAccuracy
            ? LocationAccuracy.high
            : LocationAccuracy.reduced,
        distanceFilter: _cadence.distanceFilterMeters,
      ),
    ).listen((position) {
      _applyPosition(position);

      if (_cadence.observeSpeed(position.speed)) {
        debugPrint('[TELEMETRY] Motion is now ${_cadence.motion.label}; '
            'reporting every ${_reportInterval.inSeconds}s');
        // Re-tune the GPS subscription, and report the change immediately so
        // peers learn the new cadence rather than judging us on the old one.
        _subscribePositionStream();
        _sendLatestTelemetry(force: true);
        return;
      }

      _sendLatestTelemetry();
    });
  }

  void _applyPosition(Position position) {
    _currentLat = position.latitude;
    _currentLng = position.longitude;
    _currentAlt = position.altitude;
    _currentSpeed = position.speed;
    _currentAccuracy = position.accuracy;
  }

  Future<void> _onHeartbeat() async {
    try {
      _batteryLevel = await _battery.batteryLevel;
    } catch (_) {}

    // A device that stops moving stops producing position updates, so the
    // stillness timeout has to be evaluated here too, not only on new fixes.
    if (_cadence.observeSpeed(0)) {
      debugPrint('[TELEMETRY] Motion is now ${_cadence.motion.label}; '
          'reporting every ${_reportInterval.inSeconds}s');
      _subscribePositionStream();
      await _sendLatestTelemetry(force: true);
      return;
    }

    final elapsed = _lastTelemetrySentTime == null
        ? null
        : DateTime.now().difference(_lastTelemetrySentTime!);

    if (elapsed != null && elapsed < _reportInterval && _currentLat != null) {
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 4),
        ),
      );
      _applyPosition(pos);
    } catch (_) {}

    await _sendLatestTelemetry(force: true);
  }

  Future<void> stopReporting() async {
    await _positionSubscription?.cancel();
    await _compassSubscription?.cancel();
    await _connectivitySubscription?.cancel();
    await _batterySubscription?.cancel();
    _heartbeatTimer?.cancel();
  }

  Future<void> dispose() async {
    await stopReporting();
    await _meshSubscription?.cancel();
    await _p2pSubscription?.cancel();
    await _myTelemetryController.close();
    await _teamTelemetryController.close();
    await _rejectionController.close();
  }

  Telemetry _snapshot({DateTime? at}) => Telemetry(
        operatorId: channel.myOperatorId,
        latitude: _currentLat ?? 0.0,
        longitude: _currentLng ?? 0.0,
        altitude: _currentAlt,
        speed: _currentSpeed,
        heading: _currentHeading,
        accuracy: _currentAccuracy,
        batteryLevel: _batteryLevel,
        isCharging: _isCharging,
        networkType: _netType,
        cellularSignalBars: _signalBarsForNetwork(),
        wifiSSID: '',
        timestamp: at ?? DateTime.now(),
        // Tell peers our cadence so they can judge our silence correctly. It
        // moves with us, so their staleness thresholds move with it.
        reportInterval: _reportInterval,
      );

  /// Signal strength is not exposed by the plugins in use; report it as unknown
  /// rather than the fixed "3 bars" the previous build transmitted as if measured.
  int _signalBarsForNetwork() => 0;

  bool _warnedNoFix = false;

  Future<void> _sendLatestTelemetry({bool force = false}) async {
    if (_currentLat == null || _currentLng == null) {
      // Silence here was indistinguishable from a delivery failure: a device
      // with no fix simply never appears on anyone's map. Say so once.
      if (!_warnedNoFix) {
        _warnedNoFix = true;
        debugPrint('[TELEMETRY] No position fix yet — nothing to transmit. '
            'Check location permission for this app.');
      }
      return;
    }
    _warnedNoFix = false;

    if (!force && _lastTelemetrySentTime != null) {
      if (DateTime.now().difference(_lastTelemetrySentTime!) < _reportInterval) return;
    }
    _lastTelemetrySentTime = DateTime.now();

    final tele = _snapshot();
    if (!_myTelemetryController.isClosed) _myTelemetryController.add(tele);
    _recordTeamTelemetry(tele);

    if (!await _transmit(tele)) {
      _offlineBuffer.add(tele);
      if (_offlineBuffer.length > _maxOfflineBuffer) _offlineBuffer.removeAt(0);
      return;
    }

    await _flushOfflineBuffer();
  }

  /// Seals and sends one telemetry snapshot. Buffered replays go through here
  /// too — the previous build re-sent them as raw JSON, which both leaked
  /// positions in cleartext and guaranteed receivers would reject them.
  Future<bool> _transmit(Telemetry tele) async {
    try {
      final envelope = await channel.sealTeam(
        type: MessageType.telemetry,
        plaintext: jsonEncode(tele.toJson()),
        idPrefix: 'tele',
      );

      final sentMesh = meshClient.sendMessage(envelope);
      final sentP2P = p2pMeshEngine?.sendP2PDirectMessage(envelope) ?? false;
      return sentMesh || sentP2P;
    } catch (e) {
      debugPrint('[TELEMETRY] Failed to seal telemetry: $e');
      return false;
    }
  }

  Future<void> _flushOfflineBuffer() async {
    if (_offlineBuffer.isEmpty) return;

    final pending = List<Telemetry>.from(_offlineBuffer);
    for (final buffered in pending) {
      if (await _transmit(buffered)) {
        _offlineBuffer.remove(buffered);
      } else {
        break; // Link went away again; keep the rest for the next attempt.
      }
    }
  }

  void _recordTeamTelemetry(Telemetry tele) {
    _teamLatestTelemetry[tele.operatorId] = tele;

    final history = _teamBreadcrumbs.putIfAbsent(tele.operatorId, () => <Telemetry>[]);
    history.add(tele);
    if (history.length > _maxBreadcrumbs) history.removeAt(0);

    if (!_teamTelemetryController.isClosed) {
      _teamTelemetryController.add(Map<String, Telemetry>.from(_teamLatestTelemetry));
    }
  }

  /// Transmits the current position now, bypassing the rate limit.
  ///
  /// Used when a contact is added or a route appears: the periodic heartbeat is
  /// 15-30 minutes and the position stream only fires on movement, so without
  /// this a stationary device can look absent to a peer for a very long time.
  Future<void> pushNow() => _sendLatestTelemetry(force: true);

  /// Drops all cached state for an operator that has been unpaired.
  void forgetOperator(String operatorId) {
    _teamLatestTelemetry.remove(operatorId);
    _teamBreadcrumbs.remove(operatorId);
    if (!_teamTelemetryController.isClosed) {
      _teamTelemetryController.add(Map<String, Telemetry>.from(_teamLatestTelemetry));
    }
  }
}
