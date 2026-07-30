import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/c2_message.dart';
import '../models/operator_profile.dart';
import '../ui/chat/audience_selector.dart';
import 'mesh_client.dart';
import 'p2p_mesh_engine.dart';
import 'ptt_audio_service.dart';
import 'secure_channel.dart';

enum PttCodecProfile {
  narrowband, // 12 kbps @ 16 kHz  — ~1.5 KB/s
  standard, //   24 kbps @ 22 kHz  — ~3.0 KB/s
  wideband, //   64 kbps @ 48 kHz  — ~8.0 KB/s
}

/// Captures a push-to-talk transmission and seals it to an audience.
///
/// Lifted out of the voice screen so any conversation can hold the button:
/// with the UI reorganised around contacts, push-to-talk belongs beside the
/// message composer for whoever you are talking to, not on a separate page with
/// its own audience selector.
class PttRecorder {
  static const _minTransmissionMs = 300;

  final SecureChannel channel;
  final MeshClient meshClient;
  final P2PMeshEngine p2pMeshEngine;
  final OperatorProfile myProfile;

  PttRecorder({
    required this.channel,
    required this.meshClient,
    required this.p2pMeshEngine,
    required this.myProfile,
  });

  /// True while the operator is holding the button.
  final ValueNotifier<bool> isTransmitting = ValueNotifier(false);

  /// Which conversation the live transmission is going to, so a list can show
  /// the transmitting state on the right row.
  final ValueNotifier<Audience?> activeAudience = ValueNotifier(null);

  /// Input level, for the waveform. Local animation, not network traffic.
  final ValueNotifier<double> amplitude = ValueNotifier(0);

  AudioRecorder? _recorder;
  String? _path;
  DateTime? _startedAt;
  DateTime? _pressedAt;
  Timer? _levelTimer;
  bool _busy = false;

  /// The in-flight [start], so [stop] can wait for it instead of tearing down a
  /// recorder that is still being brought up.
  ///
  /// A press shorter than the time `start` takes used to interleave the two:
  /// `stop` nulled `_recorder` while `start` was still awaiting, and `start`
  /// then either threw on a null recorder or left an orphan capture running with
  /// `isTransmitting` already false.
  Future<void>? _starting;

  /// Incremented on every press, so a `start` that finishes late can tell that
  /// its transmission has already been ended and stand down.
  int _generation = 0;

  PttCodecProfile _codec = PttCodecProfile.narrowband;

  RecordConfig get _config => switch (_codec) {
        PttCodecProfile.narrowband =>
          const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, bitRate: 12000, numChannels: 1),
        PttCodecProfile.standard =>
          const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 22050, bitRate: 24000, numChannels: 1),
        PttCodecProfile.wideband =>
          const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 48000, bitRate: 64000, numChannels: 1),
      };

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _codec = switch (prefs.getString('ptt_codec_profile')) {
      'wideband' => PttCodecProfile.wideband,
      'standard' => PttCodecProfile.standard,
      _ => PttCodecProfile.narrowband,
    };
  }

  PttCodecProfile get codec => _codec;

  Future<void> setCodec(PttCodecProfile profile) async {
    _codec = profile;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ptt_codec_profile', profile.name);
  }

  /// Begins capturing. Safe to call repeatedly; overlapping presses are ignored.
  Future<void> start(Audience audience) async {
    if (isTransmitting.value || _busy) return;
    _busy = true;
    isTransmitting.value = true;
    activeAudience.value = audience;
    _pressedAt = DateTime.now();
    _startedAt = null;
    final generation = ++_generation;

    // Haptic and a system sound rather than a generated tone: the tone used to
    // be played through audioplayers, which takes over the iOS audio session and
    // hands it back mid-recording. See PttAudioService.playTransmitCue.
    PttAudioService.playTransmitCue();

    final starting = _bringUpRecorder(generation);
    _starting = starting;
    await starting;
    _starting = null;
    _busy = false;

    // Announcing the transmission is not worth delaying the capture for: it used
    // to be awaited first, along with a 180 ms sleep for the start tone, so the
    // first word of every transmission was recorded after the operator said it.
    if (_generation == generation && isTransmitting.value) {
      unawaited(_send('PTT_START', audience));
      _startLevelAnimation();
    }
  }

  Future<void> _bringUpRecorder(int generation) async {
    try {
      await _recorder?.dispose();
      if (_generation != generation) return;

      final recorder = AudioRecorder();
      _recorder = recorder;

      var granted = await recorder.hasPermission();
      if (!granted) granted = (await Permission.microphone.request()).isGranted;

      if (!granted) {
        debugPrint('[PTT] Microphone permission denied');
        return;
      }

      // The press may already have ended while permission was being resolved.
      if (_generation != generation) {
        await recorder.dispose();
        if (_recorder == recorder) _recorder = null;
        return;
      }

      final tempDir = await getTemporaryDirectory();
      await Directory(tempDir.path).create(recursive: true);
      _path = '${tempDir.path}/ptt_${DateTime.now().microsecondsSinceEpoch}.m4a';
      await recorder.start(_config, path: _path!);
      _startedAt = DateTime.now();
    } catch (e) {
      debugPrint('[PTT] Recorder start failed: $e');
    }
  }

  /// Ends the transmission and sends the clip.
  ///
  /// Returns the captured clip so the caller can show it in the conversation,
  /// or null if nothing usable was recorded.
  Future<PttVoiceClip?> stop(Audience audience) async {
    if (!isTransmitting.value) return null;

    // Never tear down a recorder that is still coming up. Without this the two
    // interleave on a short press and the capture is lost.
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
    }

    _levelTimer?.cancel();
    final stoppedAt = DateTime.now();

    // A very short press still produces a usable clip rather than a click.
    final held = stoppedAt.difference(_pressedAt ?? stoppedAt).inMilliseconds;
    if (held < _minTransmissionMs) {
      await Future<void>.delayed(Duration(milliseconds: _minTransmissionMs - held));
    }

    isTransmitting.value = false;
    activeAudience.value = null;
    amplitude.value = 0;
    // Any late asynchronous work from this press should stand down.
    _generation++;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    String? recordedPath;
    try {
      recordedPath = await _recorder?.stop();
    } catch (e) {
      debugPrint('[PTT] Recorder stop failed: $e');
    } finally {
      await _recorder?.dispose();
      _recorder = null;
    }

    PttAudioService.playRadioClick();

    final target = recordedPath ?? _path;
    if (target == null || !File(target).existsSync()) return null;

    final bytes = await File(target).readAsBytes();
    try {
      await File(target).delete();
    } catch (_) {}

    if (bytes.length <= 100) {
      debugPrint('[PTT] Discarded empty capture');
      return null;
    }

    final durationMs = _startedAt == null
        ? held
        : stoppedAt.difference(_startedAt!).inMilliseconds;

    await _send(
      'PTT_STOP:${jsonEncode({
            'action': 'PTT_STOP',
            'audio_base64': base64Encode(bytes),
            'duration_ms': durationMs,
            'callsign': myProfile.callsign,
          })}',
      audience,
    );

    return PttVoiceClip(
      id: 'sent-${DateTime.now().microsecondsSinceEpoch}',
      senderId: myProfile.id,
      senderCallsign: 'ME',
      timestamp: DateTime.now(),
      duration: Duration(milliseconds: durationMs),
      amplitudes: const [0.6, 0.8, 0.5],
      audioData: bytes,
      isPlayed: true,
    );
  }

  /// Seals the payload to the audience and sends it on both transports.
  Future<void> _send(String payload, Audience audience) async {
    try {
      final C2Message msg;
      if (audience.isDirect) {
        final peer = audience.peer;
        if (peer == null) return;
        msg = await channel.sealDirect(
          type: MessageType.callSignaling,
          recipient: peer,
          plaintext: payload,
          idPrefix: 'ptt',
        );
      } else {
        msg = await channel.sealTeam(
          type: audience.messageType,
          plaintext: payload,
          idPrefix: 'ptt',
        );
      }

      // Voice clips are store-and-forward by design — they have to survive the
      // recipient being offline, and so do they the sender being offline.
      meshClient.sendMessage(msg, queueIfUnsent: true);
      p2pMeshEngine.sendP2PDirectMessage(msg);
    } catch (e) {
      debugPrint('[PTT] Failed to seal payload: $e');
    }
  }

  /// Local waveform animation. The old implementation pushed a network packet
  /// per frame; the level shown here is cosmetic and stays on the device.
  void _startLevelAnimation() {
    var phase = 0.0;
    _levelTimer?.cancel();
    _levelTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (!isTransmitting.value) {
        timer.cancel();
        amplitude.value = 0;
        return;
      }
      phase += 0.4;
      amplitude.value = (0.35 + 0.45 * sin(phase)).clamp(0.1, 0.95);
    });
  }

  Future<void> dispose() async {
    _levelTimer?.cancel();
    await _recorder?.dispose();
    _recorder = null;
    isTransmitting.dispose();
    activeAudience.dispose();
    amplitude.dispose();
  }
}
