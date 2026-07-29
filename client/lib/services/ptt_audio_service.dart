import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/c2_message.dart';
import 'mesh_client.dart';
import 'p2p_mesh_engine.dart';
import 'secure_channel.dart';

class PttVoiceClip {
  final String id;
  final String senderId;
  final String senderCallsign;
  final DateTime timestamp;
  final Duration duration;
  final List<double> amplitudes;
  final Uint8List audioData;
  bool isPlayed;

  PttVoiceClip({
    required this.id,
    required this.senderId,
    required this.senderCallsign,
    required this.timestamp,
    required this.duration,
    required this.amplitudes,
    required this.audioData,
    this.isPlayed = false,
  });

  int get durationSecs => max(1, duration.inSeconds);
}

class PttAudioService {
  /// Received clips are held in memory with their full audio payload, so the
  /// store has to be bounded — an unpaired flood is not possible any more, but a
  /// long operation with a chatty squad still is.
  static const _maxStoredClips = 100;
  static const _maxTempFileAge = Duration(hours: 6);

  static final List<PttVoiceClip> globalVoiceClips = [];
  static final ValueNotifier<int> clipNotifier = ValueNotifier<int>(0);
  static final ValueNotifier<String?> speakerNotifier = ValueNotifier<String?>(null);
  static final ValueNotifier<double> amplitudeNotifier = ValueNotifier<double>(0.0);
  static Function(PttVoiceClip clip, bool autoPlay)? onClipReceived;

  /// Which clip is playing, and how far through, so a conversation can render
  /// a progress bar on the voice message itself.
  static final ValueNotifier<String?> playingClipId = ValueNotifier<String?>(null);
  static final ValueNotifier<Duration> playbackPosition = ValueNotifier(Duration.zero);
  static final ValueNotifier<Duration> playbackDuration = ValueNotifier(Duration.zero);

  static StreamSubscription? _positionSub;
  static AudioPlayer? _activePlayer;
  static StreamSubscription? _playerCompleteSub;
  static File? _activeFile;
  static int _playbackGeneration = 0;

  static Timer? _callToneTimer;
  static StreamSubscription? _meshSub;
  static StreamSubscription? _p2pSub;
  static final Set<String> _processedMessageIds = <String>{};
  static final Queue<String> _processedOrder = Queue<String>();
  static DateTime? _incomingRecordingStartTime;
  static List<double> _incomingAmplitudes = [];

  static Future<void> stopActivePlayer() async {
    _playbackGeneration++;
    playingClipId.value = null;
    playbackPosition.value = Duration.zero;
    try {
      await _positionSub?.cancel();
      _positionSub = null;
      await _playerCompleteSub?.cancel();
      _playerCompleteSub = null;

      final player = _activePlayer;
      _activePlayer = null;
      if (player != null) {
        await player.stop();
        await player.dispose();
      }
    } catch (_) {
    } finally {
      await _deleteFile(_activeFile);
      _activeFile = null;
    }
  }

  static Future<void> _deleteFile(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static void startRingtone() {
    stopCallTones();
    _callToneTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      playPcmWavAudio(frequency: 850, amplitude: 0.6, durationMs: 1200);
    });
    playPcmWavAudio(frequency: 850, amplitude: 0.6, durationMs: 1200);
  }

  static void startRingbackTone() {
    stopCallTones();
    _callToneTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      playPcmWavAudio(frequency: 440, amplitude: 0.4, durationMs: 1500);
    });
    playPcmWavAudio(frequency: 440, amplitude: 0.4, durationMs: 1500);
  }

  /// Stops ringing. Cancelling the timer first and bumping the playback
  /// generation means a tone already in flight cannot re-arm the player after
  /// the call has been answered.
  static Future<void> stopCallTones() async {
    _callToneTimer?.cancel();
    _callToneTimer = null;
    await stopActivePlayer();
  }

  static void clearAllClips() {
    globalVoiceClips.clear();
    clipNotifier.value = 0;
  }

  static void clearPlayedClips() {
    globalVoiceClips.removeWhere((c) => c.isPlayed);
    clipNotifier.value = globalVoiceClips.length;
  }

  static void deleteClip(String clipId) {
    globalVoiceClips.removeWhere((c) => c.id == clipId);
    clipNotifier.value = globalVoiceClips.length;
  }

  /// Removes clips from an operator that has been unpaired.
  static void forgetOperator(String operatorId) {
    globalVoiceClips.removeWhere((c) => c.senderId == operatorId);
    clipNotifier.value = globalVoiceClips.length;
  }

  static Future<void> configureAudioOutput({required bool useLoudspeaker}) async {
    try {
      await AudioPlayer.global.setAudioContext(audioContextFor(useLoudspeaker));
    } catch (e) {
      debugPrint('[PTT] Output config failed: $e');
    }
  }

  /// Audio session for clip playback.
  ///
  /// The routing options are only legal on `playAndRecord`/`record`; pairing
  /// them with `playback` trips an assertion inside audioplayers and the whole
  /// configuration is discarded. Loudspeaker therefore uses bare `playback`,
  /// which already routes to the speaker on iOS, and earpiece uses
  /// `playAndRecord`, which routes to the receiver unless told otherwise.
  static AudioContext audioContextFor(bool useLoudspeaker) => AudioContext(
        android: AudioContextAndroid(
          stayAwake: true,
          contentType: useLoudspeaker ? AndroidContentType.music : AndroidContentType.speech,
          usageType: useLoudspeaker ? AndroidUsageType.media : AndroidUsageType.voiceCommunication,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          audioMode: useLoudspeaker ? AndroidAudioMode.normal : AndroidAudioMode.inCall,
        ),
        iOS: useLoudspeaker
            ? AudioContextIOS(
                category: AVAudioSessionCategory.playback,
                options: const {},
              )
            : AudioContextIOS(
                category: AVAudioSessionCategory.playAndRecord,
                options: const {AVAudioSessionOptions.allowBluetooth},
              ),
      );

  /// Subscribes to the mesh and P2P streams for push-to-talk clips.
  ///
  /// [channel] verifies and decrypts every envelope before a single byte of
  /// audio is written to disk or played. Live call audio no longer comes through
  /// here at all — it runs peer-to-peer over WebRTC. This path handles the
  /// store-and-forward clips, which have to survive the recipient being offline.
  static Future<void> initializeGlobalListener({
    required MeshClient meshClient,
    required P2PMeshEngine p2pMeshEngine,
    required SecureChannel channel,
    required String Function(String operatorId) resolveCallsign,
  }) async {
    await _meshSub?.cancel();
    await _p2pSub?.cancel();

    final prefs = await SharedPreferences.getInstance();
    await configureAudioOutput(useLoudspeaker: prefs.getBool('ptt_use_loudspeaker') ?? true);

    unawaited(_sweepTempAudio());

    Future<void> handle(C2Message msg) =>
        _handleGlobalMessage(msg, channel, resolveCallsign);

    _meshSub = meshClient.incomingMessages.listen(handle);
    _p2pSub = p2pMeshEngine.incomingP2PMessages.listen(handle);
  }

  static Future<void> disposeGlobalListener() async {
    await _meshSub?.cancel();
    await _p2pSub?.cancel();
    _meshSub = null;
    _p2pSub = null;
    await stopCallTones();
  }

  static Future<void> _handleGlobalMessage(
    C2Message msg,
    SecureChannel channel,
    String Function(String) resolveCallsign,
  ) async {
    if (msg.type != MessageType.callSignaling) return;
    if (msg.senderId == channel.myOperatorId) return;

    // Dedup on the envelope ID, which is unique per message. The old key hashed
    // the body with String.hashCode and wiped the whole set at 1000 entries, so
    // clips could both collide and replay.
    if (_processedMessageIds.contains(msg.id)) return;
    _processedMessageIds.add(msg.id);
    _processedOrder.add(msg.id);
    while (_processedOrder.length > 4096) {
      _processedMessageIds.remove(_processedOrder.removeFirst());
    }

    final result = await channel.open(msg);
    if (result is! OpenedMessage) return;

    final body = result.plaintext;
    if (!body.contains('PTT_')) return;

    final senderId = result.envelope.senderId;
    final callsign = resolveCallsign(senderId);

    if (body.contains('PTT_AUDIO_CHUNK')) {
      await _handleAudioChunk(body, callsign);
    } else if (body.contains('PTT_START')) {
      _incomingRecordingStartTime = DateTime.now();
      _incomingAmplitudes = [0.5];
      speakerNotifier.value = callsign;

      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('auto_play_ptt') ?? false) playRadioAlert();
    } else if (body.contains('PTT_STOP')) {
      await _handlePttStop(body, senderId, callsign);
    }
  }

  static Future<void> _handleAudioChunk(String body, String callsign) async {
    try {
      final prefix = body.contains('PTT_AUDIO_CHUNK:') ? 'PTT_AUDIO_CHUNK:' : '';
      final jsonStr = prefix.isNotEmpty ? body.replaceFirst(prefix, '') : body;
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;

      final amp = (data['amplitude'] as num?)?.toDouble() ?? 0.5;
      _incomingAmplitudes.add(amp);
      speakerNotifier.value = callsign;
      amplitudeNotifier.value = amp;

      final audioBase64 = data['audio_base64'] as String?;
      if (audioBase64 == null || audioBase64.isEmpty) return;

      final pcmBytes = base64Decode(audioBase64);
      if (pcmBytes.isNotEmpty) await playAudioBytes(pcmBytes, awaitCompletion: true);
    } catch (e) {
      debugPrint('[PTT] Malformed audio chunk: $e');
    }
  }

  static Future<void> _handlePttStop(String body, String senderId, String callsign) async {
    Uint8List audioBytes = Uint8List(0);
    var rxDuration = Duration.zero;

    try {
      if (body.startsWith('PTT_STOP:')) {
        final data = jsonDecode(body.replaceFirst('PTT_STOP:', '')) as Map<String, dynamic>;
        final audioBase64 = data['audio_base64'] as String?;
        final ms = (data['duration_ms'] as num?)?.toInt();
        if (ms != null) rxDuration = Duration(milliseconds: ms);
        if (audioBase64 != null && audioBase64.isNotEmpty) {
          audioBytes = base64Decode(audioBase64);
        }
      }
    } catch (e) {
      debugPrint('[PTT] Malformed PTT_STOP: $e');
    }

    speakerNotifier.value = null;
    amplitudeNotifier.value = 0.0;
    if (audioBytes.isEmpty) return;

    if (rxDuration == Duration.zero) {
      final started = _incomingRecordingStartTime;
      rxDuration = started == null
          ? const Duration(seconds: 1)
          : DateTime.now().difference(started);
    }

    final prefs = await SharedPreferences.getInstance();
    final autoPlay = prefs.getBool('auto_play_ptt') ?? false;

    final clip = PttVoiceClip(
      id: 'clip-${DateTime.now().microsecondsSinceEpoch}',
      senderId: senderId,
      senderCallsign: callsign,
      timestamp: DateTime.now(),
      duration: rxDuration,
      amplitudes: List.from(_incomingAmplitudes),
      audioData: audioBytes,
      isPlayed: autoPlay,
    );

    globalVoiceClips.insert(0, clip);
    while (globalVoiceClips.length > _maxStoredClips) {
      globalVoiceClips.removeLast();
    }
    clipNotifier.value = globalVoiceClips.length;

    if (autoPlay) {
      await playAudioBytes(audioBytes);
    } else {
      playRadioAlert();
    }

    onClipReceived?.call(clip, autoPlay);
  }

  /// Writes [audioBytes] to a temp file and plays it.
  ///
  /// The file is deleted when playback ends or is superseded; previously every
  /// received clip and every ringtone tone left a file behind forever, which
  /// both filled the disk and left voice traffic at rest indefinitely.
  static Future<void> playAudioBytes(Uint8List audioBytes, {bool awaitCompletion = false}) async {
    if (audioBytes.isEmpty) return;

    try {
      await stopActivePlayer();
      final generation = _playbackGeneration;

      final isWav = audioBytes.length >= 4 &&
          audioBytes[0] == 0x52 &&
          audioBytes[1] == 0x49 &&
          audioBytes[2] == 0x46 &&
          audioBytes[3] == 0x46;

      final tempDir = await getTemporaryDirectory();
      final file = File(
        '${tempDir.path}/c2_rx_${DateTime.now().microsecondsSinceEpoch}.${isWav ? 'wav' : 'm4a'}',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(audioBytes, flush: true);

      // A newer playback started while we were writing; discard this one.
      if (generation != _playbackGeneration) {
        await _deleteFile(file);
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final useLoudspeaker = prefs.getBool('ptt_use_loudspeaker') ?? true;

      final player = AudioPlayer();
      _activePlayer = player;
      _activeFile = file;

      await player.setAudioContext(audioContextFor(useLoudspeaker));
      await player.setVolume(1.0);

      final completed = Completer<void>();
      _playerCompleteSub = player.onPlayerComplete.listen((_) {
        if (!completed.isCompleted) completed.complete();
        if (generation == _playbackGeneration) unawaited(stopActivePlayer());
      });

      await player.play(DeviceFileSource(file.path));

      if (awaitCompletion) {
        // Bounded wait: a decoder that never reports completion must not wedge
        // the live-call queue.
        await completed.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () {},
        );
      }
    } catch (e) {
      debugPrint('[PTT] Playback failed: $e');
      await SystemSound.play(SystemSoundType.alert);
    }
  }

  /// Plays a clip and publishes its progress under [clipId].
  ///
  /// Voice messages live in the conversation they belong to, so the thread
  /// needs to know which bubble is playing and how far through it is.
  static Future<void> playClip(String clipId, Uint8List audioBytes, {Duration? known}) async {
    if (playingClipId.value == clipId) {
      await stopActivePlayer();
      return;
    }

    await playAudioBytes(audioBytes);

    final player = _activePlayer;
    if (player == null) return;

    playingClipId.value = clipId;
    playbackDuration.value = known ?? Duration.zero;

    _positionSub = player.onPositionChanged.listen((pos) {
      if (playingClipId.value == clipId) playbackPosition.value = pos;
    });

    try {
      final total = await player.getDuration();
      if (total != null && playingClipId.value == clipId) {
        playbackDuration.value = total;
      }
    } catch (_) {}
  }

  /// Deletes leftover audio temp files from previous runs (e.g. after a crash).
  static Future<void> _sweepTempAudio() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final cutoff = DateTime.now().subtract(_maxTempFileAge);

      await for (final entity in tempDir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('c2_rx_') && !name.startsWith('c2_tone_')) continue;

        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) await _deleteFile(entity);
      }
    } catch (e) {
      debugPrint('[PTT] Temp sweep failed: $e');
    }
  }

  static Future<void> playPcmWavAudio({
    required double frequency,
    required double amplitude,
    required int durationMs,
    bool isSquelchChirp = false,
  }) async {
    try {
      await stopActivePlayer();
      final generation = _playbackGeneration;

      final wavBytes = createWavBuffer(
        frequency: frequency,
        amplitude: amplitude,
        durationMs: durationMs,
        isSquelchChirp: isSquelchChirp,
      );

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/c2_tone_${DateTime.now().microsecondsSinceEpoch}.wav');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(wavBytes, flush: true);

      if (generation != _playbackGeneration) {
        await _deleteFile(file);
        return;
      }

      final player = AudioPlayer();
      _activePlayer = player;
      _activeFile = file;

      await player.setVolume(1.0);
      _playerCompleteSub = player.onPlayerComplete.listen((_) {
        if (generation == _playbackGeneration) unawaited(stopActivePlayer());
      });
      await player.play(DeviceFileSource(file.path));
    } catch (_) {
      await SystemSound.play(SystemSoundType.alert);
    }
  }

  /// Generates a 16-bit 8kHz mono PCM WAV buffer.
  static Uint8List createWavBuffer({
    required double frequency,
    required double amplitude,
    required int durationMs,
    bool isSquelchChirp = false,
  }) {
    const sampleRate = 8000;
    final numSamples = (sampleRate * durationMs / 1000).round();
    final dataSize = numSamples * 2;
    final bytes = ByteData(44 + dataSize);

    void writeAscii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        bytes.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    bytes.setUint32(4, 36 + dataSize, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little); // PCM
    bytes.setUint16(22, 1, Endian.little); // Mono
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    bytes.setUint32(40, dataSize, Endian.little);

    var offset = 44;
    for (var i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final currentFreq = isSquelchChirp ? frequency + (i / numSamples) * 350.0 : frequency;
      final sampleVal =
          (sin(2 * pi * currentFreq * t) * 32767 * amplitude.clamp(0.1, 0.95)).round().clamp(-32768, 32767);
      bytes.setInt16(offset, sampleVal, Endian.little);
      offset += 2;
    }

    return bytes.buffer.asUint8List();
  }

  static void playRadioAlert() {
    playPcmWavAudio(frequency: 440.0, amplitude: 0.8, durationMs: 200, isSquelchChirp: true);
    HapticFeedback.heavyImpact();
  }

  static void playRadioClick() {
    playPcmWavAudio(frequency: 880.0, amplitude: 0.6, durationMs: 100);
    HapticFeedback.lightImpact();
  }

  static void playMessageArrivalSound() {
    playPcmWavAudio(frequency: 960.0, amplitude: 0.9, durationMs: 140, isSquelchChirp: true);
    HapticFeedback.mediumImpact();
  }
}
