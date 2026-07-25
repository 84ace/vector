import 'dart:async';
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

class PttVoiceClip {
  final String id;
  final String senderCallsign;
  final DateTime timestamp;
  final int durationSecs;
  final List<double> amplitudes;
  final Uint8List audioData;
  bool isPlayed;

  PttVoiceClip({
    required this.id,
    required this.senderCallsign,
    required this.timestamp,
    required int durationSecs,
    required this.amplitudes,
    required this.audioData,
    this.isPlayed = false,
  }) : durationSecs = durationSecs > 500
            ? (durationSecs / 1000).round()
            : max(1, durationSecs);
}

class PttAudioService {
  // Global persistent store for received PTT voice clips
  static final List<PttVoiceClip> globalVoiceClips = [];
  static final ValueNotifier<int> clipNotifier = ValueNotifier<int>(0);
  static final ValueNotifier<String?> speakerNotifier = ValueNotifier<String?>(null);
  static final ValueNotifier<double> amplitudeNotifier = ValueNotifier<double>(0.0);

  static final Set<String> _processedMessageKeys = {};
  static StreamSubscription? _meshSub;
  static StreamSubscription? _p2pSub;
  static DateTime? _incomingRecordingStartTime;
  static List<double> _incomingAmplitudes = [];

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

  /// Initializes app-level global PTT listener to capture incoming audio clips on any screen
  static void initializeGlobalListener({
    required MeshClient meshClient,
    required P2PMeshEngine p2pMeshEngine,
    required String myOperatorId,
  }) {
    _meshSub?.cancel();
    _p2pSub?.cancel();

    void handleGlobalMessage(C2Message msg) async {
      if (msg.senderId == myOperatorId) return;

      final body = msg.encryptedBody;
      if (!body.contains('PTT_') && !body.contains('CALL_VOICE_STREAM')) return;

      // Synchronous top-level deduplication guard
      final msgKey = '${msg.senderId}_${body.hashCode}';
      if (_processedMessageKeys.contains(msgKey)) return;
      _processedMessageKeys.add(msgKey);
      if (_processedMessageKeys.length > 1000) {
        _processedMessageKeys.clear();
      }

      if (body.contains('PTT_AUDIO_CHUNK') || body.contains('CALL_VOICE_STREAM')) {
        try {
          final prefix = body.contains('CALL_VOICE_STREAM:')
              ? 'CALL_VOICE_STREAM:'
              : (body.contains('PTT_AUDIO_CHUNK:') ? 'PTT_AUDIO_CHUNK:' : '');
          final jsonStr = prefix.isNotEmpty ? body.replaceFirst(prefix, '') : body;
          final Map<String, dynamic> data = jsonDecode(jsonStr);
          final amp = (data['amplitude'] as num?)?.toDouble() ?? 0.5;
          final callsign = data['callsign'] ?? msg.senderId;
          final audioBase64 = data['audio_base64'] as String?;

          _incomingAmplitudes.add(amp);
          speakerNotifier.value = callsign;
          amplitudeNotifier.value = amp;

          if (audioBase64 != null && audioBase64.isNotEmpty && msg.senderId != myOperatorId) {
            final pcmBytes = base64Decode(audioBase64);
            if (pcmBytes.isNotEmpty) {
              playAudioBytes(pcmBytes);
            }
          }
        } catch (_) {}
      } else if (body.contains('PTT_START')) {
        _incomingRecordingStartTime = DateTime.now();
        _incomingAmplitudes = [0.5];
        speakerNotifier.value = msg.senderId;

        final prefs = await SharedPreferences.getInstance();
        final autoPlay = prefs.getBool('auto_play_ptt') ?? true;
        if (autoPlay) {
          playRadioAlert();
        }
      } else if (body.contains('PTT_STOP')) {
        Uint8List audioBytes = Uint8List(0);
        int rxDurationSecs = 0;
        try {
          if (body.startsWith('PTT_STOP:')) {
            final Map<String, dynamic> data = jsonDecode(body.replaceFirst('PTT_STOP:', ''));
            final audioBase64 = data['audio_base64'] as String?;
            rxDurationSecs = (data['duration_secs'] as num?)?.toInt() ?? 0;
            if (audioBase64 != null && audioBase64.isNotEmpty) {
              audioBytes = base64Decode(audioBase64);
            }
          }
        } catch (_) {}

        speakerNotifier.value = null;
        amplitudeNotifier.value = 0.0;

        final prefs = await SharedPreferences.getInstance();
        final autoPlay = prefs.getBool('auto_play_ptt') ?? true;
        final durationSecs = rxDurationSecs > 0
            ? rxDurationSecs
            : max(1, DateTime.now().difference(_incomingRecordingStartTime ?? DateTime.now()).inSeconds);

        if (audioBytes.isNotEmpty) {
          final clip = PttVoiceClip(
            id: 'clip-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1000)}',
            senderCallsign: msg.senderId,
            timestamp: DateTime.now(),
            durationSecs: durationSecs,
            amplitudes: List.from(_incomingAmplitudes),
            audioData: audioBytes,
            isPlayed: autoPlay,
          );

          globalVoiceClips.insert(0, clip);
          clipNotifier.value = globalVoiceClips.length;

          if (autoPlay) {
            playAudioBytes(audioBytes);
          } else {
            playRadioAlert();
          }
          debugPrint('[PTT GLOBAL STORE] Saved voice clip from ${msg.senderId}, total clips=${globalVoiceClips.length}, autoPlay=$autoPlay');
        }
      }
    }

    _meshSub = meshClient.incomingMessages.listen(handleGlobalMessage);
    _p2pSub = p2pMeshEngine.incomingP2PMessages.listen(handleGlobalMessage);
  }

  /// Plays native recorded voice audio bytes over hardware media speakers safely across macOS & Android
  static Future<void> playAudioBytes(Uint8List audioBytes) async {
    if (audioBytes.isEmpty) return;
    try {
      final isWav = audioBytes.length >= 4 &&
          audioBytes[0] == 0x52 && // R
          audioBytes[1] == 0x49 && // I
          audioBytes[2] == 0x46 && // F
          audioBytes[3] == 0x46;   // F

      final ext = isWav ? 'wav' : 'm4a';

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/rx_voice_${DateTime.now().millisecondsSinceEpoch}.$ext');
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      await file.writeAsBytes(audioBytes, flush: true);

      final player = AudioPlayer();
      await player.setVolume(1.0);
      await player.play(DeviceFileSource(file.path));

      player.onPlayerComplete.listen((_) {
        player.dispose();
      });

      debugPrint('[PTT AUDIO SERVICE] Playing ${audioBytes.length} bytes voice payload ($ext) via standalone AudioPlayer');
    } catch (e) {
      debugPrint('[PTT PLAY ERROR] $e');
      SystemSound.play(SystemSoundType.alert);
    }
  }

  /// Plays synthesized 16-bit PCM audio WAV data over native device speakers
  static Future<void> playPcmWavAudio({
    required double frequency,
    required double amplitude,
    required int durationMs,
    bool isSquelchChirp = false,
  }) async {
    try {
      final wavBytes = createWavBuffer(
        frequency: frequency,
        amplitude: amplitude,
        durationMs: durationMs,
        isSquelchChirp: isSquelchChirp,
      );

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/rx_squelch_${DateTime.now().millisecondsSinceEpoch}.wav');
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      await file.writeAsBytes(wavBytes, flush: true);

      final player = AudioPlayer();
      await player.setVolume(1.0);
      await player.play(DeviceFileSource(file.path));

      player.onPlayerComplete.listen((_) {
        player.dispose();
      });
    } catch (_) {
      SystemSound.play(SystemSoundType.alert);
    }
  }

  /// Generates a valid 16-bit 8000Hz mono PCM WAV audio file buffer
  static Uint8List createWavBuffer({
    required double frequency,
    required double amplitude,
    required int durationMs,
    bool isSquelchChirp = false,
  }) {
    const sampleRate = 8000;
    final numSamples = (sampleRate * durationMs / 1000).round();
    final dataSize = numSamples * 2; // 16-bit mono = 2 bytes per sample
    final fileSize = 36 + dataSize;

    final bytes = ByteData(44 + dataSize);

    // 1. RIFF Header
    bytes.setUint8(0, 0x52); // R
    bytes.setUint8(1, 0x49); // I
    bytes.setUint8(2, 0x46); // F
    bytes.setUint8(3, 0x46); // F
    bytes.setUint32(4, fileSize, Endian.little);
    bytes.setUint8(8, 0x57);  // W
    bytes.setUint8(9, 0x41);  // A
    bytes.setUint8(10, 0x56); // V
    bytes.setUint8(11, 0x45); // E

    // 2. fmt Subchunk
    bytes.setUint8(12, 0x66); // f
    bytes.setUint8(13, 0x6D); // m
    bytes.setUint8(14, 0x74); // t
    bytes.setUint8(15, 0x20); // space
    bytes.setUint32(16, 16, Endian.little); // Subchunk1Size (16 for PCM)
    bytes.setUint16(20, 1, Endian.little);  // AudioFormat (1 for PCM)
    bytes.setUint16(22, 1, Endian.little);  // NumChannels (1 mono)
    bytes.setUint32(24, sampleRate, Endian.little); // SampleRate (8000)
    bytes.setUint32(28, sampleRate * 2, Endian.little); // ByteRate
    bytes.setUint16(32, 2, Endian.little);  // BlockAlign
    bytes.setUint16(34, 16, Endian.little); // BitsPerSample (16)

    // 3. data Subchunk
    bytes.setUint8(36, 0x64); // d
    bytes.setUint8(37, 0x61); // a
    bytes.setUint8(38, 0x74); // t
    bytes.setUint8(39, 0x61); // a
    bytes.setUint32(40, dataSize, Endian.little);

    // 4. PCM Audio Samples
    int offset = 44;
    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      double currentFreq = frequency;
      if (isSquelchChirp) {
        currentFreq = frequency + (i / numSamples) * 350.0;
      }
      final sampleVal = (sin(2 * pi * currentFreq * t) * 32767 * amplitude.clamp(0.1, 0.95)).round().clamp(-32768, 32767);
      bytes.setInt16(offset, sampleVal, Endian.little);
      offset += 2;
    }

    return bytes.buffer.asUint8List();
  }

  /// Plays radio tactical alert chirp across devices
  static void playRadioAlert() {
    playPcmWavAudio(frequency: 440.0, amplitude: 0.8, durationMs: 200, isSquelchChirp: true);
    HapticFeedback.heavyImpact();
  }

  /// Plays radio click squelch sound
  static void playRadioClick() {
    playPcmWavAudio(frequency: 880.0, amplitude: 0.6, durationMs: 100);
    HapticFeedback.lightImpact();
  }
}
