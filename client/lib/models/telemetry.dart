enum NetworkType { wifi, cellular, offline }

class Telemetry {
  final String operatorId;
  final double latitude;
  final double longitude;
  final double altitude; // meters MSL
  final double speed; // m/s
  final double heading; // degrees 0-360
  final double accuracy; // meters
  final int batteryLevel; // 0-100%
  final bool isCharging;
  final NetworkType networkType;
  final int cellularSignalBars; // 0-4
  final String wifiSSID;
  final DateTime timestamp;

  /// How often the sender expects to report, as it reported it.
  ///
  /// Freshness has to be judged against the sender's own cadence. A device on
  /// a 30-minute low-battery heartbeat is behaving perfectly at 20 minutes of
  /// silence; a device reporting every 15 seconds is not.
  final Duration reportInterval;

  Telemetry({
    required this.operatorId,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.speed,
    required this.heading,
    required this.accuracy,
    required this.batteryLevel,
    required this.isCharging,
    required this.networkType,
    required this.cellularSignalBars,
    required this.wifiSSID,
    required this.timestamp,
    this.reportInterval = const Duration(minutes: 15),
  });

  /// Silence beyond this means the operator has missed reports.
  Duration get _staleAfter => reportInterval * 2.5;

  /// Silence beyond this means we should stop trusting the position at all.
  Duration get _offlineAfter => reportInterval * 5;

  Duration get age => DateTime.now().difference(timestamp);

  Telemetry copyWith({String? operatorId}) => Telemetry(
        operatorId: operatorId ?? this.operatorId,
        latitude: latitude,
        longitude: longitude,
        altitude: altitude,
        speed: speed,
        heading: heading,
        accuracy: accuracy,
        batteryLevel: batteryLevel,
        isCharging: isCharging,
        networkType: networkType,
        cellularSignalBars: cellularSignalBars,
        wifiSSID: wifiSSID,
        timestamp: timestamp,
        reportInterval: reportInterval,
      );

  /// True once the operator has missed roughly two expected reports.
  ///
  /// This was a flat one minute, while a stationary device only transmits on a
  /// 15-to-30-minute heartbeat — so every healthy peer read "STALE SIGNAL"
  /// almost permanently, and the indicator carried no information.
  bool get isStale => age > _staleAfter;

  bool get isOffline => age > _offlineAfter;

  Map<String, dynamic> toJson() => {
        'operator_id': operatorId,
        'latitude': latitude,
        'longitude': longitude,
        'altitude': altitude,
        'speed': speed,
        'heading': heading,
        'accuracy': accuracy,
        'battery_level': batteryLevel,
        'is_charging': isCharging,
        'network_type': networkType.name,
        'cellular_signal_bars': cellularSignalBars,
        'wifi_ssid': wifiSSID,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'report_interval_ms': reportInterval.inMilliseconds,
      };

  factory Telemetry.fromJson(Map<String, dynamic> json) {
    return Telemetry(
      operatorId: json['operator_id'] ?? '',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      altitude: (json['altitude'] as num?)?.toDouble() ?? 0.0,
      speed: (json['speed'] as num?)?.toDouble() ?? 0.0,
      heading: (json['heading'] as num?)?.toDouble() ?? 0.0,
      accuracy: (json['accuracy'] as num?)?.toDouble() ?? 0.0,
      batteryLevel: json['battery_level'] ?? 100,
      isCharging: json['is_charging'] ?? false,
      networkType: NetworkType.values.firstWhere(
        (e) => e.name == json['network_type'],
        orElse: () => NetworkType.offline,
      ),
      cellularSignalBars: json['cellular_signal_bars'] ?? 0,
      wifiSSID: json['wifi_ssid'] ?? '',
      timestamp: json['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['timestamp'])
          : DateTime.now(),
      reportInterval: json['report_interval_ms'] is int
          ? Duration(milliseconds: json['report_interval_ms'] as int)
          : const Duration(minutes: 15),
    );
  }
}
