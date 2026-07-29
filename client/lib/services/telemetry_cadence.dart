import 'dart:math';

import '../models/telemetry.dart';

/// How the operator is moving, inferred from GPS speed.
enum MotionState {
  /// Not meaningfully moving. Position is worth confirming occasionally.
  stationary,

  /// Walking or running. Position changes at a human pace.
  onFoot,

  /// In a vehicle. Position goes stale fastest and matters most.
  vehicle,
}

extension MotionStateLabel on MotionState {
  String get label => switch (this) {
        MotionState.stationary => 'STATIONARY',
        MotionState.onFoot => 'ON FOOT',
        MotionState.vehicle => 'MOBILE',
      };
}

/// Decides how often this device should report its position.
///
/// A single fixed interval cannot serve both ends of the problem: fast enough
/// to track someone in a vehicle drains the battery of someone sitting still,
/// and slow enough to be kind to a stationary device loses a moving one. The
/// interval is therefore derived from what the device is actually doing.
///
/// Three inputs, in order of weight:
///   * **Motion** sets the base rate — this is what actually determines how
///     quickly a position becomes wrong.
///   * **Power** stretches it as the battery falls, because a flat handset
///     reports nothing at all.
///   * **Link** stretches it on cellular, where each report costs metered data.
///
/// The result is clamped per motion state so the multipliers cannot compound
/// into something useless — a moving operator on a weak battery over cellular
/// still reports often enough to be followed.
class TelemetryCadence {
  /// Base rate by motion state.
  static const _base = {
    MotionState.vehicle: Duration(seconds: 15),
    MotionState.onFoot: Duration(seconds: 60),
    MotionState.stationary: Duration(minutes: 10),
  };

  /// Floor and ceiling per motion state, applied after the multipliers.
  static const _bounds = {
    MotionState.vehicle: (Duration(seconds: 10), Duration(seconds: 120)),
    MotionState.onFoot: (Duration(seconds: 30), Duration(minutes: 5)),
    MotionState.stationary: (Duration(minutes: 5), Duration(minutes: 30)),
  };

  /// Speed thresholds, in m/s, with hysteresis between them.
  static const _vehicleEntry = 4.0; // ~14 km/h
  static const _vehicleExit = 2.5;
  static const _footEntry = 0.7; // ~2.5 km/h
  static const _footExit = 0.4;

  /// How long movement must be absent before falling back to stationary.
  /// GPS speed jitters around zero on a still device, so a single slow sample
  /// must not flip the state.
  static const _stillnessDwell = Duration(seconds: 90);

  MotionState _motion = MotionState.stationary;
  DateTime? _lastMovingAt;

  MotionState get motion => _motion;

  /// Folds a new speed sample into the motion estimate.
  ///
  /// Returns true when the state changed, which the caller uses to re-tune the
  /// position stream — a stationary device does not need high-accuracy fixes.
  bool observeSpeed(double speedMetersPerSecond, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final previous = _motion;
    final speed = speedMetersPerSecond.isFinite ? max(0.0, speedMetersPerSecond) : 0.0;

    // Entry thresholds are higher than exit thresholds, so noise around a
    // boundary cannot oscillate the state.
    if (speed >= _vehicleEntry) {
      _motion = MotionState.vehicle;
      _lastMovingAt = at;
    } else if (speed >= _footEntry ||
        (_motion == MotionState.vehicle && speed >= _vehicleExit)) {
      _motion = _motion == MotionState.vehicle && speed >= _vehicleExit
          ? MotionState.vehicle
          : MotionState.onFoot;
      _lastMovingAt = at;
    } else if (speed >= _footExit && _motion != MotionState.stationary) {
      // Drifting slowly: hold the current state rather than dropping out.
      _lastMovingAt = at;
    } else {
      final since = _lastMovingAt;
      if (since == null || at.difference(since) >= _stillnessDwell) {
        _motion = MotionState.stationary;
      }
    }

    return _motion != previous;
  }

  /// The reporting interval for the current motion state and conditions.
  Duration intervalFor({
    required int batteryLevel,
    required bool isCharging,
    required NetworkType network,
  }) =>
      intervalForState(
        motion: _motion,
        batteryLevel: batteryLevel,
        isCharging: isCharging,
        network: network,
      );

  /// Pure form of the policy, so it can be reasoned about and tested directly.
  static Duration intervalForState({
    required MotionState motion,
    required int batteryLevel,
    required bool isCharging,
    required NetworkType network,
  }) {
    final base = _base[motion]!;

    final powerFactor = isCharging
        ? 1.0
        : batteryLevel > 50
            ? 1.0
            : batteryLevel >= 20
                ? 1.75
                : 3.0;

    // Wi-Fi is effectively free; cellular is metered and, in the field, often
    // the scarcer resource. Offline is not a rate question — those reports are
    // buffered and flushed when a link returns.
    final linkFactor = network == NetworkType.cellular ? 1.5 : 1.0;

    final scaled = Duration(
      milliseconds: (base.inMilliseconds * powerFactor * linkFactor).round(),
    );

    final (floor, ceiling) = _bounds[motion]!;
    if (scaled < floor) return floor;
    if (scaled > ceiling) return ceiling;
    return scaled;
  }

  /// Distance the operator must travel before the OS wakes us with a new fix.
  ///
  /// Tightening this while moving and relaxing it while still is the other half
  /// of the power saving: it governs how often the GPS subsystem reports at all,
  /// independent of how often we transmit.
  int get distanceFilterMeters => switch (_motion) {
        MotionState.vehicle => 25,
        MotionState.onFoot => 10,
        MotionState.stationary => 50,
      };

  /// Whether the current state justifies high-accuracy positioning.
  bool get wantsHighAccuracy => _motion != MotionState.stationary;
}
