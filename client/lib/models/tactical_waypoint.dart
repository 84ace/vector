enum WaypointType { rallyPoint, target, hazard, observationPost, custom }

class TacticalWaypoint {
  final String id;
  final String name;
  final WaypointType type;
  final double latitude;
  final double longitude;
  final String createdByCallsign;
  final DateTime timestamp;

  TacticalWaypoint({
    required this.id,
    required this.name,
    required this.type,
    required this.latitude,
    required this.longitude,
    required this.createdByCallsign,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'latitude': latitude,
        'longitude': longitude,
        'created_by_callsign': createdByCallsign,
        'timestamp': timestamp.millisecondsSinceEpoch,
      };

  factory TacticalWaypoint.fromJson(Map<String, dynamic> json) {
    return TacticalWaypoint(
      id: json['id'] ?? '',
      name: json['name'] ?? 'WAYPOINT',
      type: WaypointType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => WaypointType.rallyPoint,
      ),
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      createdByCallsign: json['created_by_callsign'] ?? 'HQ',
      timestamp: json['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['timestamp'])
          : DateTime.now(),
    );
  }
}
