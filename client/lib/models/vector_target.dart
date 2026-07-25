import 'dart:math';

class VectorResult {
  final String targetName;
  final double fromLat;
  final double fromLng;
  final double toLat;
  final double toLng;
  final double distanceMeters;
  final double azimuthDegrees; // True North bearing
  final double relativeHeadingDegrees; // Bearing relative to operator compass heading
  final double altitudeDeltaMeters;
  final Duration estimatedTimeOfArrival;

  VectorResult({
    required this.targetName,
    required this.fromLat,
    required this.fromLng,
    required this.toLat,
    required this.toLng,
    required this.distanceMeters,
    required this.azimuthDegrees,
    required this.relativeHeadingDegrees,
    required this.altitudeDeltaMeters,
    required this.estimatedTimeOfArrival,
  });

  String get formattedDistance {
    if (distanceMeters >= 1000) {
      return '${(distanceMeters / 1000).toStringAsFixed(2)} km';
    }
    return '${distanceMeters.toStringAsFixed(0)} m';
  }

  String get formattedAzimuth {
    return '${azimuthDegrees.toStringAsFixed(1)}° M';
  }

  String get formattedETA {
    final mins = estimatedTimeOfArrival.inMinutes;
    final secs = estimatedTimeOfArrival.inSeconds % 60;
    if (mins > 60) {
      final hrs = estimatedTimeOfArrival.inHours;
      return '${hrs}h ${mins % 60}m';
    }
    return '${mins}m ${secs}s';
  }

  static VectorResult calculate({
    required String targetName,
    required double fromLat,
    required double fromLng,
    required double fromAlt,
    required double toLat,
    required double toLng,
    required double toAlt,
    required double currentSpeedMps,
    required double currentCompassHeading,
  }) {
    const double earthRadiusMeters = 6371000.0;
    final double dLat = _toRadians(toLat - fromLat);
    final double dLng = _toRadians(toLng - fromLng);

    final double lat1 = _toRadians(fromLat);
    final double lat2 = _toRadians(toLat);

    final double a = sin(dLat / 2) * sin(dLat / 2) +
        sin(dLng / 2) * sin(dLng / 2) * cos(lat1) * cos(lat2);
    final double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    final double distance = earthRadiusMeters * c;

    // Calculate initial bearing
    final double y = sin(dLng) * cos(lat2);
    final double x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
    double bearing = _toDegrees(atan2(y, x));
    bearing = (bearing + 360) % 360;

    double relativeHeading = (bearing - currentCompassHeading + 360) % 360;

    double speed = currentSpeedMps > 0.5 ? currentSpeedMps : 1.4; // default 1.4 m/s walking speed
    int etaSeconds = (distance / speed).round();

    return VectorResult(
      targetName: targetName,
      fromLat: fromLat,
      fromLng: fromLng,
      toLat: toLat,
      toLng: toLng,
      distanceMeters: distance,
      azimuthDegrees: bearing,
      relativeHeadingDegrees: relativeHeading,
      altitudeDeltaMeters: toAlt - fromAlt,
      estimatedTimeOfArrival: Duration(seconds: etaSeconds),
    );
  }

  static double _toRadians(double degrees) => degrees * pi / 180.0;
  static double _toDegrees(double radians) => radians * 180.0 / pi;
}
