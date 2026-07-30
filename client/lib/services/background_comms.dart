import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Why background comms are not running, when they are not.
enum BackgroundCommsStatus {
  /// Running: the process is protected and telemetry keeps going out.
  active,

  /// Not attempted, because this platform needs no help. On iOS the background
  /// location and audio modes in Info.plist do this job declaratively — there is
  /// no service to start.
  notRequired,

  /// The platform refused. On Android this is Android 12+ declining a
  /// foreground service started from the background, or Android 14+ declining a
  /// location-typed one when the location permission is not held.
  refused,

  /// Stopped, either explicitly or because the app is shutting down.
  stopped,
}

/// Keeps comms running while the app is not in the foreground.
///
/// The two platforms need opposite things, and the difference is worth stating
/// because it determines what an operator can rely on:
///
///   * **Android** kills backgrounded processes, so it needs a foreground
///     service holding the process open. Once running, everything works exactly
///     as it does in the foreground: relay socket, P2P discovery, telemetry,
///     incoming messages and call signalling.
///   * **iOS** never lets a socket stay open indefinitely, and no entitlement
///     changes that. The `location` and `audio` background modes keep telemetry
///     flowing and PTT audio playing, but once the system suspends the app an
///     incoming call or message will not wake it. That needs a push, which needs
///     the relay to talk to APNs — and would put Apple in the metadata path.
///     Deliberately not done; see SECURITY.md.
class BackgroundComms {
  static const _channel = MethodChannel('vector/background');

  /// Injectable so tests can drive the platform boundary without a device.
  @visibleForTesting
  final Future<bool?> Function(String method)? invoke;

  /// Overrides platform detection in tests.
  @visibleForTesting
  final bool? isAndroidOverride;

  BackgroundComms({this.invoke, this.isAndroidOverride});

  BackgroundCommsStatus _status = BackgroundCommsStatus.stopped;
  BackgroundCommsStatus get status => _status;

  bool get _isAndroid => isAndroidOverride ?? Platform.isAndroid;

  Future<bool?> _call(String method) =>
      invoke != null ? invoke!(method) : _channel.invokeMethod<bool>(method);

  /// Starts background comms, returning the resulting status.
  ///
  /// Must be called while the app is in the foreground: Android 12 and later
  /// refuse a foreground service started from the background, so deferring this
  /// until `onPaused` — the intuitive place — is exactly what does not work.
  ///
  /// Call only after location permission has been granted, or Android 14+ will
  /// refuse the location-typed service.
  Future<BackgroundCommsStatus> start() async {
    if (!_isAndroid) {
      _status = BackgroundCommsStatus.notRequired;
      return _status;
    }

    bool started;
    try {
      started = await _call('start') ?? false;
    } on PlatformException catch (e) {
      debugPrint('[BACKGROUND] Could not start foreground service: ${e.message}');
      started = false;
    } on MissingPluginException {
      // Running under a host that has no platform side, e.g. a widget test.
      started = false;
    }

    _status = started ? BackgroundCommsStatus.active : BackgroundCommsStatus.refused;
    return _status;
  }

  Future<void> stop() async {
    if (!_isAndroid) {
      _status = BackgroundCommsStatus.stopped;
      return;
    }
    try {
      await _call('stop');
    } on PlatformException catch (e) {
      debugPrint('[BACKGROUND] Could not stop foreground service: ${e.message}');
    } on MissingPluginException {
      // Nothing to stop.
    }
    _status = BackgroundCommsStatus.stopped;
  }

  /// One line for the operator's event log, or null when there is nothing worth
  /// saying. Silence is correct on iOS, where nothing was started because
  /// nothing needed starting.
  String? get advisory {
    switch (_status) {
      case BackgroundCommsStatus.active:
        return 'Background comms are running. Telemetry keeps transmitting and '
            'messages keep arriving while Vector is not on screen, and a '
            'notification stays visible for as long as that is true.';
      case BackgroundCommsStatus.refused:
        return 'Background comms could not start, so telemetry and messages stop '
            'when Vector leaves the screen. Android refuses this without the '
            'location permission granted — check location is set to "Allow all '
            'the time".';
      case BackgroundCommsStatus.notRequired:
      case BackgroundCommsStatus.stopped:
        return null;
    }
  }
}
