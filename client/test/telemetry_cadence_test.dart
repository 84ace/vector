import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/models/telemetry.dart';
import 'package:vector_c2/services/telemetry_cadence.dart';

void main() {
  Duration policy({
    required MotionState motion,
    int battery = 90,
    bool charging = false,
    NetworkType network = NetworkType.wifi,
  }) =>
      TelemetryCadence.intervalForState(
        motion: motion,
        batteryLevel: battery,
        isCharging: charging,
        network: network,
      );

  group('reporting interval', () {
    test('motion sets the base rate', () {
      final vehicle = policy(motion: MotionState.vehicle);
      final onFoot = policy(motion: MotionState.onFoot);
      final still = policy(motion: MotionState.stationary);

      expect(vehicle, lessThan(onFoot));
      expect(onFoot, lessThan(still));
      expect(vehicle, const Duration(seconds: 15));
      expect(still, const Duration(minutes: 10));
    });

    test('a low battery slows reporting down', () {
      final healthy = policy(motion: MotionState.onFoot, battery: 90);
      final low = policy(motion: MotionState.onFoot, battery: 30);
      final critical = policy(motion: MotionState.onFoot, battery: 10);

      expect(low, greaterThan(healthy));
      expect(critical, greaterThan(low));
    });

    test('charging ignores the battery level', () {
      expect(
        policy(motion: MotionState.onFoot, battery: 5, charging: true),
        policy(motion: MotionState.onFoot, battery: 100, charging: true),
      );
    });

    test('cellular reports less often than wi-fi', () {
      expect(
        policy(motion: MotionState.onFoot, network: NetworkType.cellular),
        greaterThan(policy(motion: MotionState.onFoot, network: NetworkType.wifi)),
      );
    });

    test('a moving operator stays followable in the worst conditions', () {
      // The whole point of the clamps: multipliers must not compound into
      // something useless. Someone in a vehicle on a dying phone over cellular
      // still has to be trackable.
      final worst = policy(
        motion: MotionState.vehicle,
        battery: 5,
        network: NetworkType.cellular,
      );
      expect(worst, lessThanOrEqualTo(const Duration(seconds: 120)));

      final worstOnFoot = policy(
        motion: MotionState.onFoot,
        battery: 5,
        network: NetworkType.cellular,
      );
      expect(worstOnFoot, lessThanOrEqualTo(const Duration(minutes: 5)));
    });

    test('a stationary operator never spams, even at full battery on wi-fi', () {
      expect(
        policy(motion: MotionState.stationary, battery: 100, charging: true),
        greaterThanOrEqualTo(const Duration(minutes: 5)),
      );
    });
  });

  group('motion detection', () {
    test('sustained speed enters the vehicle state', () {
      final c = TelemetryCadence();
      expect(c.observeSpeed(12.0), isTrue);
      expect(c.motion, MotionState.vehicle);
    });

    test('walking pace is on foot, not a vehicle', () {
      final c = TelemetryCadence();
      c.observeSpeed(1.4);
      expect(c.motion, MotionState.onFoot);
    });

    test('GPS jitter does not flap a stationary device into motion', () {
      // A still handset reports small non-zero speeds. Without hysteresis this
      // would oscillate the state and re-tune the GPS stream continuously.
      final c = TelemetryCadence();
      var changes = 0;
      for (final noise in [0.0, 0.3, 0.1, 0.35, 0.0, 0.2, 0.3]) {
        if (c.observeSpeed(noise)) changes++;
      }
      expect(c.motion, MotionState.stationary);
      expect(changes, 0, reason: 'noise must not produce state changes');
    });

    test('slowing briefly does not immediately drop out of motion', () {
      final start = DateTime(2026, 1, 1, 12);
      final c = TelemetryCadence();

      c.observeSpeed(10.0, now: start);
      expect(c.motion, MotionState.vehicle);

      // Stopped at a junction: still within the dwell window.
      c.observeSpeed(0.0, now: start.add(const Duration(seconds: 30)));
      expect(c.motion, MotionState.vehicle,
          reason: 'a brief halt is not the end of the journey');
    });

    test('prolonged stillness settles to stationary', () {
      final start = DateTime(2026, 1, 1, 12);
      final c = TelemetryCadence();

      c.observeSpeed(10.0, now: start);
      final changed = c.observeSpeed(0.0, now: start.add(const Duration(minutes: 3)));

      expect(changed, isTrue);
      expect(c.motion, MotionState.stationary);
    });
  });

  group('position stream tuning', () {
    test('a still device relaxes accuracy and distance', () {
      final c = TelemetryCadence();
      expect(c.wantsHighAccuracy, isFalse);
      expect(c.distanceFilterMeters, greaterThan(25));
    });

    test('a moving device tightens them', () {
      final c = TelemetryCadence()..observeSpeed(1.5);
      expect(c.wantsHighAccuracy, isTrue);
      expect(c.distanceFilterMeters, lessThanOrEqualTo(10));
    });
  });

  group('freshness follows cadence', () {
    test('peers judge a moving operator on its faster interval', () {
      // The staleness threshold is derived from the reported interval, so the
      // two stay consistent automatically as conditions change.
      final moving = TelemetryCadence.intervalForState(
        motion: MotionState.vehicle,
        batteryLevel: 90,
        isCharging: false,
        network: NetworkType.wifi,
      );

      Telemetry sample(Duration age, Duration interval) => Telemetry(
            operatorId: 'op-abc',
            latitude: 1,
            longitude: 2,
            altitude: 0,
            speed: 0,
            heading: 0,
            accuracy: 5,
            batteryLevel: 90,
            isCharging: false,
            networkType: NetworkType.wifi,
            cellularSignalBars: 0,
            wifiSSID: '',
            timestamp: DateTime.now().subtract(age),
            reportInterval: interval,
          );

      expect(sample(const Duration(seconds: 20), moving).isStale, isFalse);
      expect(sample(const Duration(minutes: 2), moving).isStale, isTrue);
    });
  });
}
