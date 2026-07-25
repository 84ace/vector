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
  });

  bool get isStale {
    final age = DateTime.now().difference(timestamp);
    return age.inMinutes >= 1;
  }

  bool get isOffline {
    final age = DateTime.now().difference(timestamp);
    return age.inMinutes >= 5;
  }

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
    );
  }
}
