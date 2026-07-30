import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/services/background_comms.dart';

/// Background comms controller.
///
/// The platform halves cannot be unit tested — a foreground service and
/// UIBackgroundModes are verified by building and running. What is testable, and
/// what these cover, is the decision logic around them: that a refusal is
/// reported rather than swallowed, that iOS is not asked to start a service it
/// has no concept of, and that a missing platform side does not throw.
void main() {
  group('Android', () {
    test('a successful start reports active and says so', () async {
      final calls = <String>[];
      final comms = BackgroundComms(
        isAndroidOverride: true,
        invoke: (m) async {
          calls.add(m);
          return true;
        },
      );

      expect(await comms.start(), BackgroundCommsStatus.active);
      expect(calls, ['start']);
      expect(comms.advisory, contains('Background comms are running'));
    });

    test('a refusal is surfaced, not swallowed', () async {
      // Android 12+ refuses a service started from the background, and 14+
      // refuses a location-typed one without the location permission. Both mean
      // telemetry silently stops the moment the app leaves the screen, so the
      // operator has to be told.
      final comms = BackgroundComms(
        isAndroidOverride: true,
        invoke: (_) async => false,
      );

      expect(await comms.start(), BackgroundCommsStatus.refused);
      expect(comms.advisory, isNotNull);
      expect(comms.advisory, contains('could not start'));
      expect(comms.advisory, contains('all the time'),
          reason: 'the advisory should name the fix, not just the symptom');
    });

    test('a PlatformException is treated as a refusal, not a crash', () async {
      final comms = BackgroundComms(
        isAndroidOverride: true,
        invoke: (_) async => throw PlatformException(code: 'ERR'),
      );
      expect(await comms.start(), BackgroundCommsStatus.refused);
    });

    test('a missing platform side does not throw', () async {
      // Widget tests and any host without the MethodChannel registered.
      final comms = BackgroundComms(
        isAndroidOverride: true,
        invoke: (_) async => throw MissingPluginException('no impl'),
      );
      expect(await comms.start(), BackgroundCommsStatus.refused);
    });

    test('stop is forwarded and clears the status', () async {
      final calls = <String>[];
      final comms = BackgroundComms(
        isAndroidOverride: true,
        invoke: (m) async {
          calls.add(m);
          return true;
        },
      );

      await comms.start();
      await comms.stop();
      expect(calls, ['start', 'stop']);
      expect(comms.status, BackgroundCommsStatus.stopped);
      expect(comms.advisory, isNull, reason: 'nothing to report once stopped');
    });

    test('a failure to stop still leaves the status stopped', () async {
      final comms = BackgroundComms(
        isAndroidOverride: true,
        invoke: (m) async {
          if (m == 'stop') throw PlatformException(code: 'ERR');
          return true;
        },
      );
      await comms.start();
      await comms.stop();
      expect(comms.status, BackgroundCommsStatus.stopped);
    });
  });

  group('non-Android', () {
    test('no service is started, and nothing is reported', () async {
      // iOS gets its background behaviour from UIBackgroundModes declaratively.
      // Asking the platform to start a service would fail every launch and fill
      // the event log with a warning about something that is working correctly.
      var invoked = false;
      final comms = BackgroundComms(
        isAndroidOverride: false,
        invoke: (_) async {
          invoked = true;
          return true;
        },
      );

      expect(await comms.start(), BackgroundCommsStatus.notRequired);
      expect(invoked, isFalse, reason: 'there is no service to start on iOS');
      expect(comms.advisory, isNull);
    });

    test('stop is a no-op rather than an error', () async {
      var invoked = false;
      final comms = BackgroundComms(
        isAndroidOverride: false,
        invoke: (_) async {
          invoked = true;
          return true;
        },
      );
      await comms.start();
      await comms.stop();
      expect(invoked, isFalse);
      expect(comms.status, BackgroundCommsStatus.stopped);
    });
  });
}
