import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/operator_profile.dart';
import '../../models/c2_message.dart';
import '../../services/mesh_client.dart';
import '../../services/p2p_mesh_engine.dart';
import '../../services/ptt_audio_service.dart';
import '../theme/c2_colors.dart';

enum PttTargetScope {
  direct,
  group,
  broadcast,
}

class CallView extends StatefulWidget {
  final OperatorProfile myProfile;
  final List<OperatorProfile> teamProfiles;
  final OperatorProfile? activePeer;
  final bool isCallActive;
  final VoidCallback? onCallEnded;
  final MeshClient meshClient;
  final P2PMeshEngine p2pMeshEngine;

  const CallView({
    super.key,
    required this.myProfile,
    required this.teamProfiles,
    this.activePeer,
    this.isCallActive = false,
    this.onCallEnded,
    required this.meshClient,
    required this.p2pMeshEngine,
  });

  @override
  State<CallView> createState() => _CallViewState();
}

enum PttCodecProfile {
  narrowband, // 12 kbps, 16 kHz sample rate, 8 kHz audio bandwidth (~1.5 KB/s)
  standard,   // 24 kbps, 22.05 kHz sample rate, 11 kHz audio bandwidth (~3.0 KB/s)
  wideband,   // 64 kbps, 48 kHz sample rate, 24 kHz audio bandwidth (~8.0 KB/s)
}

class _CallViewState extends State<CallView> {
  // Fresh Instance Hardware Audio Recorders
  AudioRecorder? _pttRecorder;
  AudioRecorder? _voiceCallRecorder;
  bool _isVoiceCallLoopRunning = false;
  String? _currentRecordingPath;
  DateTime? _actualRecordingStartTime;

  // PTT Radio State
  PttTargetScope _pttScope = PttTargetScope.direct;
  OperatorProfile? _selectedPeer;
  bool _isPttPressed = false;
  bool _autoPlayPtt = false;
  bool _useLoudspeaker = true;
  PttCodecProfile _codecProfile = PttCodecProfile.narrowband;
  String? _incomingPttSpeakerCallsign;
  double _currentAmplitude = 0.0;

  // Full-Duplex Voice/Video Call State
  bool _isInActiveCall = false;
  bool _isCallConnected = false;
  bool _isVideoCall = false;
  bool _isMuted = false;
  bool _isCameraOff = false;
  int _callDurationSecs = 0;
  Timer? _callTimer;

  bool _isTestingMic = false;
  String _micTestStatus = '';

  Timer? _pttAudioStreamTimer;
  Timer? _voiceCallStreamTimer;
  final List<double> _audioWaveform = List.generate(28, (_) => 0.05);

  // PTT Voice Clip Card Audio Playback State
  String? _playingClipId;
  double _clipPlaybackProgress = 0.0;
  Duration _clipPosition = Duration.zero;
  Duration _clipDuration = Duration.zero;
  AudioPlayer? _clipPlayer;
  StreamSubscription? _clipPosSub;
  StreamSubscription? _clipCompleteSub;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _selectedPeer = widget.activePeer;
    if (_selectedPeer == null) {
      final selectable = widget.teamProfiles.where((p) => p.id != widget.myProfile.id).toList();
      if (selectable.isNotEmpty) {
        _selectedPeer = selectable.first;
      }
    }

    if (widget.isCallActive) {
      _isInActiveCall = true;
      _startCallDurationTimer();
      _startCallAudioStream();
    }

    PttAudioService.clipNotifier.addListener(_onClipsUpdated);
    PttAudioService.speakerNotifier.addListener(_onSpeakerUpdated);
    PttAudioService.amplitudeNotifier.addListener(_onAmplitudeUpdated);

    void handleIncomingMessages(C2Message msg) {
      if (!mounted) return;
      if (msg.senderId == widget.myProfile.id) return;

      final body = msg.encryptedBody;

      if (body.contains('CALL_VOICE_STREAM')) {
        try {
          final prefix = body.contains('CALL_VOICE_STREAM:') ? 'CALL_VOICE_STREAM:' : '';
          final jsonStr = prefix.isNotEmpty ? body.replaceFirst(prefix, '') : body;
          final Map<String, dynamic> data = jsonDecode(jsonStr);
          final amp = (data['amplitude'] as num?)?.toDouble() ?? 0.5;
          final audioBase64 = data['audio_base64'] as String?;

          if (_isInActiveCall) {
            setState(() {
              _currentAmplitude = amp;
              _updateWaveformFromAmplitude(amp);
            });

            if (audioBase64 != null && audioBase64.isNotEmpty) {
              final pcmBytes = base64Decode(audioBase64);
              if (pcmBytes.isNotEmpty) {
                PttAudioService.playAudioBytes(pcmBytes);
              }
            }
          }
        } catch (_) {}
      } else if (body.contains('CALL_ACCEPT')) {
        final sender = widget.teamProfiles.firstWhere(
          (p) => p.id == msg.senderId || p.callsign == msg.senderId,
          orElse: () => _selectedPeer ?? widget.teamProfiles.first,
        );
        setState(() {
          _selectedPeer = sender;
          _isInActiveCall = true;
          _isCallConnected = true;
          _callDurationSecs = 0;
        });
        _startCallDurationTimer();
        _startCallAudioStream();
        PttAudioService.playRadioClick();
      } else if (body.contains('CALL_INITIATE_VOICE')) {
        final sender = widget.teamProfiles.firstWhere(
          (p) => p.id == msg.senderId || p.callsign == msg.senderId,
          orElse: () => _selectedPeer ?? widget.teamProfiles.first,
        );
        setState(() {
          _selectedPeer = sender;
          _isVideoCall = false;
        });
      } else if (body.contains('CALL_INITIATE_VIDEO')) {
        final sender = widget.teamProfiles.firstWhere(
          (p) => p.id == msg.senderId || p.callsign == msg.senderId,
          orElse: () => _selectedPeer ?? widget.teamProfiles.first,
        );
        setState(() {
          _selectedPeer = sender;
          _isVideoCall = true;
        });
      } else if (body.contains('CALL_END')) {
        _endCall(transmit: false);
      }
    }

    widget.meshClient.incomingMessages.listen(handleIncomingMessages);
    widget.p2pMeshEngine.incomingP2PMessages.listen(handleIncomingMessages);
  }

  RecordConfig get _currentRecordConfig {
    switch (_codecProfile) {
      case PttCodecProfile.narrowband:
        // Narrowband Profile: 12 kbps @ 16 kHz mono (8 kHz Audio Bandwidth, ~1.5 KB/s)
        return const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, bitRate: 12000, numChannels: 1);
      case PttCodecProfile.wideband:
        // Wideband HD Profile: 64 kbps @ 48 kHz mono (24 kHz Audio Bandwidth, ~8.0 KB/s)
        return const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 48000, bitRate: 64000, numChannels: 1);
      case PttCodecProfile.standard:
        // Standard Profile: 24 kbps @ 22.05 kHz mono (11 kHz Audio Bandwidth, ~3.0 KB/s)
        return const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 22050, bitRate: 24000, numChannels: 1);
    }
  }

  void _onClipsUpdated() {
    if (!mounted) return;
    setState(() {});
  }

  void _onSpeakerUpdated() {
    if (!mounted) return;
    setState(() {
      _incomingPttSpeakerCallsign = PttAudioService.speakerNotifier.value;
    });
  }

  void _onAmplitudeUpdated() {
    if (!mounted) return;
    final amp = PttAudioService.amplitudeNotifier.value;
    setState(() {
      _currentAmplitude = amp;
      _updateWaveformFromAmplitude(amp);
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final codecName = prefs.getString('ptt_codec_profile') ?? 'narrowband';
    final loudspeaker = prefs.getBool('ptt_use_loudspeaker') ?? true;
    setState(() {
      _autoPlayPtt = prefs.getBool('auto_play_ptt') ?? false;
      _useLoudspeaker = loudspeaker;
      if (codecName == 'narrowband') {
        _codecProfile = PttCodecProfile.narrowband;
      } else if (codecName == 'wideband') {
        _codecProfile = PttCodecProfile.wideband;
      } else {
        _codecProfile = PttCodecProfile.standard;
      }
    });
    PttAudioService.configureAudioOutput(useLoudspeaker: loudspeaker);
  }

  Future<void> _saveAutoPlaySetting(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_play_ptt', val);
    if (!mounted) return;
    setState(() {
      _autoPlayPtt = val;
    });
  }

  Future<void> _saveAudioOutputSetting(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ptt_use_loudspeaker', val);
    if (!mounted) return;
    setState(() {
      _useLoudspeaker = val;
    });
    await PttAudioService.configureAudioOutput(useLoudspeaker: val);
  }

  Future<void> _saveCodecProfile(PttCodecProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ptt_codec_profile', profile.name);
    if (!mounted) return;
    setState(() {
      _codecProfile = profile;
    });
  }

  @override
  void didUpdateWidget(covariant CallView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activePeer != null && widget.activePeer?.id != _selectedPeer?.id) {
      setState(() {
        _selectedPeer = widget.activePeer;
      });
    }
    if (widget.isCallActive && !_isInActiveCall) {
      setState(() {
        _isInActiveCall = true;
        _callDurationSecs = 0;
      });
      _startCallDurationTimer();
      _startCallAudioStream();
    } else if (!widget.isCallActive && _isInActiveCall) {
      _endCall(transmit: false);
    }
  }

  @override
  void dispose() {
    PttAudioService.clipNotifier.removeListener(_onClipsUpdated);
    PttAudioService.speakerNotifier.removeListener(_onSpeakerUpdated);
    PttAudioService.amplitudeNotifier.removeListener(_onAmplitudeUpdated);
    _clipPosSub?.cancel();
    _clipCompleteSub?.cancel();
    try {
      _clipPlayer?.stop();
      _clipPlayer?.dispose();
    } catch (_) {}
    _clipPlayer = null;
    _pttRecorder?.dispose();
    try {
      _voiceCallRecorder?.dispose();
    } catch (_) {}
    _voiceCallRecorder = null;
    _pttAudioStreamTimer?.cancel();
    _voiceCallStreamTimer?.cancel();
    _callTimer?.cancel();
    super.dispose();
  }

  void _startCallDurationTimer() {
    _callTimer?.cancel();
    _callTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _callDurationSecs++;
      });
    });
  }

  void _startCallAudioStream() async {
    if (_isVoiceCallLoopRunning) return;
    _isVoiceCallLoopRunning = true;

    while (_isInActiveCall && mounted) {
      if (_isMuted) {
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }

      final recorder = AudioRecorder();
      _voiceCallRecorder = recorder;

      try {
        bool hasPerm = await recorder.hasPermission();
        if (!hasPerm) {
          final status = await Permission.microphone.request();
          hasPerm = status.isGranted;
        }

        if (!hasPerm || !_isInActiveCall || _isMuted || !mounted) {
          await recorder.dispose();
          _voiceCallRecorder = null;
          await Future.delayed(const Duration(milliseconds: 250));
          continue;
        }

        final tempDir = await getTemporaryDirectory();
        final chunkPath = '${tempDir.path}/call_mic_${DateTime.now().millisecondsSinceEpoch}.m4a';

        await recorder.start(_currentRecordConfig, path: chunkPath);

        // Record 600ms hardware mic voice audio per chunk for low-latency continuous stream
        await Future.delayed(const Duration(milliseconds: 600));

        if (!_isInActiveCall || !mounted) {
          try {
            await recorder.stop();
          } catch (_) {}
          await recorder.dispose();
          _voiceCallRecorder = null;
          break;
        }

        final recordedPath = await recorder.stop();
        await recorder.dispose();
        _voiceCallRecorder = null;

        final targetPath = recordedPath ?? chunkPath;
        if (File(targetPath).existsSync()) {
          final audioBytes = await File(targetPath).readAsBytes();
          try {
            File(targetPath).deleteSync();
          } catch (_) {}

          if (audioBytes.length > 80 && _isInActiveCall && !_isMuted && mounted) {
            final payload = jsonEncode({
              'action': 'CALL_VOICE_STREAM',
              'amplitude': 0.75,
              'audio_base64': base64Encode(audioBytes),
              'callsign': widget.myProfile.callsign,
            });

            _sendCallSignal('CALL_VOICE_STREAM:$payload');
            debugPrint('[VOICE CALL TX] Transmitted ${audioBytes.length} bytes continuous audio chunk');
          }
        }
      } catch (e) {
        debugPrint('[VOICE CALL RECORDER ERROR] $e');
        try {
          await recorder.dispose();
        } catch (_) {}
        _voiceCallRecorder = null;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }

    _isVoiceCallLoopRunning = false;
  }

  // Real Hardware Microphone Loopback Test
  void _runHardwareMicTest() async {
    if (_isTestingMic) return;
    setState(() {
      _isTestingMic = true;
      _micTestStatus = 'RECORDING (SPEAK NOW... 3s)';
    });

    final testRecorder = AudioRecorder();

    try {
      bool hasPerm = await testRecorder.hasPermission();
      if (!hasPerm) {
        final status = await Permission.microphone.request();
        hasPerm = status.isGranted;
      }

      if (hasPerm) {
        final tempDir = await getTemporaryDirectory();
        final path = '${tempDir.path}/mictest_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await testRecorder.start(
          _currentRecordConfig,
          path: path,
        );

        double phase = 0.0;
        for (int i = 0; i < 30; i++) {
          await Future.delayed(const Duration(milliseconds: 100));
          if (!mounted) break;
          phase += 0.3;
          final simAmp = (0.35 + 0.45 * sin(phase)).clamp(0.1, 0.95);
          setState(() {
            _currentAmplitude = simAmp;
            _updateWaveformFromAmplitude(simAmp);
          });
        }

        await Future.delayed(const Duration(milliseconds: 150));
        final recordedPath = await testRecorder.stop();

        if (recordedPath != null && File(recordedPath).existsSync()) {
          final bytes = await File(recordedPath).readAsBytes();
          debugPrint('[MIC TEST] Recorded ${bytes.length} bytes audio');
          setState(() {
            _micTestStatus = 'PLAYING BACK ${bytes.length} BYTES...';
          });
          await PttAudioService.playAudioBytes(bytes);
          setState(() {
            _micTestStatus = 'MIC TEST PASSED (${bytes.length} bytes captured)';
          });
        } else {
          setState(() {
            _micTestStatus = 'FAILED: 0 BYTES RECORDED';
          });
        }
      } else {
        setState(() {
          _micTestStatus = 'PERMISSION DENIED';
        });
      }
    } catch (e) {
      setState(() {
        _micTestStatus = 'ERROR: $e';
      });
    } finally {
      testRecorder.dispose();
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        setState(() {
          _isTestingMic = false;
          _resetWaveform();
        });
      }
    }
  }

  bool _isPttBusy = false;
  DateTime? _pttPressTime;

  void _startPttTransmission() async {
    if (_isPttPressed || _isPttBusy) return;
    _isPttBusy = true;
    _isPttPressed = true;
    _pttPressTime = DateTime.now();

    setState(() {});

    debugPrint('[PTT TX] Transmission started...');
    PttAudioService.playRadioAlert();
    await Future.delayed(const Duration(milliseconds: 180));
    _sendPttPayload('PTT_START');

    try {
      _pttRecorder?.dispose();
      _pttRecorder = AudioRecorder();

      bool hasPerm = await _pttRecorder!.hasPermission();
      if (!hasPerm) {
        final status = await Permission.microphone.request();
        hasPerm = status.isGranted;
      }

      if (hasPerm) {
        final tempDir = await getTemporaryDirectory();
        Directory(tempDir.path).createSync(recursive: true);
        _currentRecordingPath = '${tempDir.path}/ptt_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _pttRecorder!.start(
          _currentRecordConfig,
          path: _currentRecordingPath!,
        );
        _actualRecordingStartTime = DateTime.now();
        debugPrint('[PTT TX] Fresh AudioRecorder started with config sampleRate=${_currentRecordConfig.sampleRate} bitRate=${_currentRecordConfig.bitRate} on path: $_currentRecordingPath');
      } else {
        debugPrint('[PTT TX ERROR] Microphone permission DENIED by system');
      }
    } catch (e) {
      debugPrint('[PTT RECORDER START ERROR] $e');
    }

    _isPttBusy = false;

    // Gentle local UI waveform animation WITHOUT high-frequency network flooding
    double phase = 0.0;
    _pttAudioStreamTimer?.cancel();
    _pttAudioStreamTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (!_isPttPressed || !mounted) {
        timer.cancel();
        return;
      }

      phase += 0.4;
      final simAmp = (0.35 + 0.45 * sin(phase)).clamp(0.1, 0.95);

      if (mounted) {
        setState(() {
          _currentAmplitude = simAmp;
          _updateWaveformFromAmplitude(simAmp);
        });
      }
    });
  }

  void _stopPttTransmission() async {
    if (!_isPttPressed) return;
    _pttAudioStreamTimer?.cancel();
    final recStopTime = DateTime.now();

    final elapsed = DateTime.now().difference(_pttPressTime ?? DateTime.now()).inMilliseconds;
    if (elapsed < 300) {
      await Future.delayed(Duration(milliseconds: 300 - elapsed));
    }

    setState(() {
      _isPttPressed = false;
      _currentAmplitude = 0.0;
      _resetWaveform();
    });

    await Future.delayed(const Duration(milliseconds: 200));

    String audioBase64 = '';
    String? targetPath;

    try {
      if (_pttRecorder != null) {
        final recordedPath = await _pttRecorder!.stop();
        debugPrint('[PTT TX] Recorder stop returned path: $recordedPath');
        targetPath = recordedPath ?? _currentRecordingPath;
      }

      if (targetPath != null && File(targetPath).existsSync()) {
        final audioBytes = await File(targetPath).readAsBytes();
        debugPrint('[PTT TX] Captured ${audioBytes.length} bytes recorded voice audio from $targetPath');
        if (audioBytes.length > 100) {
          audioBase64 = base64Encode(audioBytes);
        }
      }
    } catch (e) {
      debugPrint('[PTT RECORDER STOP ERROR] $e');
    } finally {
      _pttRecorder?.dispose();
      _pttRecorder = null;
      _isPttBusy = false;
      PttAudioService.playRadioClick();

      if (audioBase64.isNotEmpty) {
        final recMs = _actualRecordingStartTime != null
            ? recStopTime.difference(_actualRecordingStartTime!).inMilliseconds
            : elapsed;
        final clipDurationSecs = max(1, (recMs / 1000).round());
        if (targetPath != null && File(targetPath).existsSync()) {
          final audioBytes = await File(targetPath).readAsBytes();
          final clip = PttVoiceClip(
            id: 'sent-clip-${DateTime.now().millisecondsSinceEpoch}',
            senderCallsign: 'ME (SENT)',
            timestamp: DateTime.now(),
            durationSecs: clipDurationSecs,
            amplitudes: [0.6, 0.8, 0.5],
            audioData: audioBytes,
            isPlayed: true,
          );
          PttAudioService.globalVoiceClips.insert(0, clip);
          PttAudioService.clipNotifier.value = PttAudioService.globalVoiceClips.length;
        }

        final payload = jsonEncode({
          'action': 'PTT_STOP',
          'audio_base64': audioBase64,
          'duration_secs': clipDurationSecs,
          'callsign': widget.myProfile.callsign,
        });
        _sendPttPayload('PTT_STOP:$payload');
        debugPrint('[PTT TX] PTT_STOP payload sent (${audioBase64.length} base64 chars)');
      } else {
        debugPrint('[PTT TX] WARNING: Audio recording was empty (0 bytes captured), skipping empty transmission.');
      }
    }
  }

  void _updateWaveformFromAmplitude(double amplitude) {
    final center = _audioWaveform.length / 2;
    for (int i = 0; i < _audioWaveform.length; i++) {
      final distFromCenter = (i - center).abs() / center;
      final gaussianWeight = exp(-pow(distFromCenter * 2.2, 2));
      final noise = (Random().nextDouble() - 0.5) * 0.15;
      _audioWaveform[i] = (amplitude * gaussianWeight + noise).clamp(0.05, 1.0);
    }
  }

  void _resetWaveform() {
    for (int i = 0; i < _audioWaveform.length; i++) {
      _audioWaveform[i] = 0.05;
    }
  }

  void _playRecordedClip(PttVoiceClip clip) async {
    if (_playingClipId == clip.id && _clipPlayer != null) {
      _clipPosSub?.cancel();
      _clipCompleteSub?.cancel();
      try {
        await _clipPlayer?.stop();
        await _clipPlayer?.dispose();
      } catch (_) {}
      _clipPlayer = null;
      if (mounted) {
        setState(() {
          _playingClipId = null;
          _clipPlaybackProgress = 0.0;
        });
      }
      return;
    }

    _clipPosSub?.cancel();
    _clipCompleteSub?.cancel();
    try {
      await _clipPlayer?.stop();
      await _clipPlayer?.dispose();
    } catch (_) {}
    _clipPlayer = null;

    clip.isPlayed = true;
    PttAudioService.clipNotifier.value = PttAudioService.globalVoiceClips.length;

    try {
      final isWav = clip.audioData.length >= 4 &&
          clip.audioData[0] == 0x52 &&
          clip.audioData[1] == 0x49 &&
          clip.audioData[2] == 0x46 &&
          clip.audioData[3] == 0x46;
      final ext = isWav ? 'wav' : 'm4a';

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/play_clip_${clip.id}.$ext');
      await file.writeAsBytes(clip.audioData, flush: true);

      final player = AudioPlayer();
      _clipPlayer = player;

      setState(() {
        _playingClipId = clip.id;
        _clipPlaybackProgress = 0.0;
        _clipPosition = Duration.zero;
        _clipDuration = Duration(seconds: max(1, clip.durationSecs));
      });

      await player.setVolume(1.0);
      await player.play(DeviceFileSource(file.path));

      _clipPosSub = player.onPositionChanged.listen((p) {
        if (!mounted || _playingClipId != clip.id) return;
        final totalMs = max(1, _clipDuration.inMilliseconds);
        final currentMs = p.inMilliseconds.clamp(0, totalMs);
        setState(() {
          _clipPosition = p;
          _clipPlaybackProgress = (currentMs / totalMs).clamp(0.0, 1.0);
        });
      });

      player.onDurationChanged.listen((d) {
        if (!mounted || _playingClipId != clip.id) return;
        setState(() {
          _clipDuration = d;
        });
      });

      _clipCompleteSub = player.onPlayerComplete.listen((_) async {
        try {
          await player.stop();
          await player.dispose();
        } catch (_) {}
        if (_clipPlayer == player) {
          _clipPlayer = null;
        }
        if (mounted) {
          setState(() {
            _playingClipId = null;
            _clipPlaybackProgress = 0.0;
            _clipPosition = Duration.zero;
          });
        }
      });
    } catch (e) {
      debugPrint('[CLIP PLAY ERROR] $e');
    }
  }

  void _sendPttPayload(String action) {
    String? recipientId;
    MessageType type = MessageType.callSignaling;

    if (_pttScope == PttTargetScope.direct) {
      if (_selectedPeer != null) {
        recipientId = _selectedPeer!.id;
      }
      type = MessageType.callSignaling;
    } else if (_pttScope == PttTargetScope.group) {
      type = MessageType.chatGroup;
    } else {
      type = MessageType.broadcast;
    }

    final msgId = 'ptt-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1000)}';

    final pttMsg = C2Message(
      id: msgId,
      type: type,
      senderId: widget.myProfile.id,
      senderPublicKey: widget.myProfile.publicKey,
      recipientId: recipientId,
      groupId: 'grp-strike-team-alpha',
      encryptedBody: action,
      timestamp: DateTime.now(),
      isMe: true,
    );

    widget.meshClient.sendMessage(pttMsg);

    bool delivered = false;
    if (recipientId != null) {
      delivered = widget.p2pMeshEngine.sendP2PDirectMessage(pttMsg);
    }
    if (!delivered) {
      widget.p2pMeshEngine.broadcastP2PMessage(pttMsg);
    }
  }

  void _sendCallSignal(String action) {
    if (_selectedPeer == null) return;

    final signalMsg = C2Message(
      id: 'call-${DateTime.now().millisecondsSinceEpoch}',
      type: MessageType.callSignaling,
      senderId: widget.myProfile.id,
      senderPublicKey: widget.myProfile.publicKey,
      recipientId: _selectedPeer!.id,
      encryptedBody: action,
      timestamp: DateTime.now(),
      isMe: true,
    );

    widget.meshClient.sendMessage(signalMsg);
    bool delivered = widget.p2pMeshEngine.sendP2PDirectMessage(signalMsg);
    if (!delivered) {
      widget.p2pMeshEngine.broadcastP2PMessage(signalMsg);
    }
  }

  void _startCall(bool isVideo) {
    if (_selectedPeer == null) return;
    setState(() {
      _isInActiveCall = true;
      _isVideoCall = isVideo;
      _callDurationSecs = 0;
    });

    _startCallDurationTimer();
    _startCallAudioStream();

    final action = isVideo ? 'CALL_INITIATE_VIDEO' : 'CALL_INITIATE_VOICE';
    _sendCallSignal(action);
    PttAudioService.playRadioClick();
  }

  void _endCall({bool transmit = true}) async {
    if (transmit) {
      _sendCallSignal('CALL_END');
    }
    _callTimer?.cancel();
    _voiceCallStreamTimer?.cancel();
    try {
      await _pttRecorder?.stop().timeout(const Duration(seconds: 1), onTimeout: () => null);
    } catch (_) {}
    try {
      await _voiceCallRecorder?.stop().timeout(const Duration(seconds: 1), onTimeout: () => null);
      await _voiceCallRecorder?.dispose();
    } catch (_) {}
    _voiceCallRecorder = null;

    setState(() {
      _isInActiveCall = false;
      _isVideoCall = false;
      _callDurationSecs = 0;
      _resetWaveform();
    });
    widget.onCallEnded?.call();
  }

  String _formatDuration(int totalSecs) {
    int secs = totalSecs > 500 ? (totalSecs / 1000).round() : totalSecs;
    if (secs < 0) secs = 0;
    final mins = secs ~/ 60;
    final remSecs = secs % 60;
    return '${mins.toString().padLeft(2, '0')}:${remSecs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_isInActiveCall) {
      return _buildActiveCallScreen();
    }

    final selectablePeers = widget.teamProfiles.where((p) => p.id != widget.myProfile.id).toList();

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () {
          if (!_isPttPressed) {
            _startPttTransmission();
          } else {
            _stopPttTransmission();
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: const Color(0xFF0F172A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF1E293B),
            title: const Row(
              children: [
                Icon(Icons.mic, color: Colors.cyanAccent, size: 20),
                SizedBox(width: 8),
                Text(
                  'PTT AUDIO & CALLS',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.tune, color: Colors.cyanAccent),
                tooltip: 'PTT & Audio Settings',
                onPressed: () => _showPttSettingsModal(context),
              ),
            ],
          ),
          body: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              children: [
                // Encryption Badge
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  color: C2Colors.emeraldAccent.withOpacity(0.15),
                  child: const Row(
                    children: [
                      Icon(Icons.verified_user, color: C2Colors.emeraldAccent, size: 13),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'WebRTC Mic Active (Spacebar / Hold PTT Button)',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: C2Colors.emeraldAccent, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 10),

                // Contact Cards Target Selector (for Direct PTT or Voice/Video Calls)
                if (_pttScope == PttTargetScope.direct && selectablePeers.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'SELECT INDIVIDUAL RECIPIENT CONTACT',
                              style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                            ),
                            Text(
                              'TARGET: ${_selectedPeer?.callsign ?? "NONE"}',
                              style: const TextStyle(color: C2Colors.emeraldAccent, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          height: 56,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: selectablePeers.length,
                            itemBuilder: (ctx, idx) {
                              final peer = selectablePeers[idx];
                              final isSelected = _selectedPeer?.id == peer.id;

                              return InkWell(
                                onTap: () {
                                  setState(() {
                                    _selectedPeer = peer;
                                  });
                                },
                                child: Container(
                                  margin: const EdgeInsets.only(right: 8),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isSelected ? Colors.cyan.withOpacity(0.25) : C2Colors.slateCard,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isSelected ? Colors.cyanAccent : Colors.white12,
                                      width: isSelected ? 2.0 : 1.0,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 16,
                                        backgroundColor: const Color(0xFF0F172A),
                                        child: Text(
                                          peer.callsign.substring(0, min(2, peer.callsign.length)),
                                          style: TextStyle(color: isSelected ? Colors.cyanAccent : Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(peer.callsign, style: TextStyle(color: isSelected ? Colors.cyanAccent : Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                          Text(peer.name, style: const TextStyle(color: Colors.white54, fontSize: 9)),
                                        ],
                                      ),
                                      if (isSelected) ...[
                                        const SizedBox(width: 6),
                                        const Icon(Icons.check_circle, color: Colors.cyanAccent, size: 14),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 10),

                // Call Action Buttons (Full Duplex Voice & Video)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0284C7),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          icon: const Icon(Icons.phone, size: 16),
                          label: Text(
                            'START VOICE CALL WITH ${_selectedPeer?.callsign ?? "TARGET"}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10),
                          ),
                          onPressed: selectablePeers.isNotEmpty ? () => _startCall(false) : null,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: C2Colors.emeraldAccent,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          icon: const Icon(Icons.videocam, size: 16),
                          label: Text(
                            'VIDEO CALL ${_selectedPeer?.callsign ?? "TARGET"}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10),
                          ),
                          onPressed: selectablePeers.isNotEmpty ? () => _startCall(true) : null,
                        ),
                      ),
                    ],
                  ),
                ),

                // Stored PTT Voice Clips Section (when !_autoPlayPtt)
                if (PttAudioService.globalVoiceClips.isNotEmpty) ...[
                  const Divider(color: Colors.white12, height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.record_voice_over, color: Colors.amberAccent, size: 14),
                            SizedBox(width: 6),
                            Text(
                              'STORED VOICE CLIPS',
                              style: TextStyle(color: Colors.amberAccent, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            InkWell(
                              onTap: () {
                                PttAudioService.clearPlayedClips();
                              },
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                child: Text('CLEAR LISTENED', style: TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.bold)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: () {
                                PttAudioService.clearAllClips();
                              },
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                child: Text('CLEAR ALL', style: TextStyle(color: Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 96,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: PttAudioService.globalVoiceClips.length,
                      itemBuilder: (ctx, idx) {
                        return _buildPttClipCard(PttAudioService.globalVoiceClips[idx]);
                      },
                    ),
                  ),
                ],

                const Divider(color: Colors.white12, height: 16),

                // Squad Member Audio Monitor Grid
                SizedBox(
                  height: 150,
                  child: GridView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 2.5,
                    ),
                    itemCount: widget.teamProfiles.length,
                    itemBuilder: (context, index) {
                      final op = widget.teamProfiles[index];
                      final isSpeakingMe = _isPttPressed && op.id == widget.myProfile.id;
                      final isIncomingSpeaker = _incomingPttSpeakerCallsign == op.id || _incomingPttSpeakerCallsign == op.callsign;
                      final activeSpeaking = isSpeakingMe || isIncomingSpeaker;

                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: activeSpeaking ? C2Colors.emeraldAccent : Colors.white12,
                            width: activeSpeaking ? 2.5 : 1.0,
                          ),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: const Color(0xFF0F172A),
                              child: Text(
                                op.callsign.substring(0, min(2, op.callsign.length)),
                                style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 11),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    op.callsign,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                                  ),
                                  Text(
                                    activeSpeaking ? 'TX AUDIO' : 'IDLE / READY',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: activeSpeaking ? C2Colors.emeraldAccent : Colors.white38,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                // Real Audio Spectrum Visualizer
                Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _isPttPressed
                                ? 'TX MIC (${_codecProfile == PttCodecProfile.narrowband ? "12 kbps • 8 kHz BW" : (_codecProfile == PttCodecProfile.wideband ? "64 kbps HD • 24 kHz BW" : "24 kbps • 11 kHz BW")})'
                                : (_incomingPttSpeakerCallsign != null ? 'RX AUDIO STREAM ACTIVE' : 'REAL HARDWARE MIC SPECTRUM'),
                            style: TextStyle(
                              color: _isPttPressed || _incomingPttSpeakerCallsign != null ? C2Colors.emeraldAccent : Colors.white38,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Live Mic Input Stream',
                            style: TextStyle(color: Colors.cyanAccent.withOpacity(0.6), fontSize: 9, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 28,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: _audioWaveform.map((val) {
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 60),
                              width: 3.5,
                              height: 28 * val,
                              decoration: BoxDecoration(
                                color: _isPttPressed
                                    ? C2Colors.emeraldAccent
                                    : (_incomingPttSpeakerCallsign != null ? Colors.cyanAccent : Colors.white24),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                ),

                // PTT Hold Button (Supported on Desktop Mouse Clicks, Touch Gestures, & Spacebar Key)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (_) => _startPttTransmission(),
                        onTapUp: (_) => _stopPttTransmission(),
                        onTapCancel: () => _stopPttTransmission(),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 100),
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isPttPressed ? C2Colors.emeraldAccent : const Color(0xFF0284C7),
                            border: Border.all(
                              color: _isPttPressed ? Colors.white : Colors.cyanAccent,
                              width: 3.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _isPttPressed ? C2Colors.emeraldAccent.withOpacity(0.7) : Colors.black45,
                                blurRadius: _isPttPressed ? 20 : 6,
                                spreadRadius: _isPttPressed ? 5 : 1,
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _isPttPressed ? Icons.graphic_eq : Icons.mic,
                                color: _isPttPressed ? Colors.black : Colors.white,
                                size: 28,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _isPttPressed ? 'RECORDING' : 'HOLD PTT',
                                style: TextStyle(
                                  color: _isPttPressed ? Colors.black : Colors.white,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amberAccent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: const Icon(Icons.radio_button_checked, color: Colors.red, size: 20),
                        label: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Text('TAP TO RECORD 5s VOICE CLIP', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
                            Text('Auto-packages & sends recorded mic audio', style: TextStyle(color: Colors.black87, fontSize: 8)),
                          ],
                        ),
                        onPressed: _isPttPressed ? null : () async {
                          _startPttTransmission();
                          await Future.delayed(const Duration(seconds: 5));
                          _stopPttTransmission();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPttClipCard(PttVoiceClip clip) {
    final isCurrentPlaying = _playingClipId == clip.id;
    final progress = isCurrentPlaying ? _clipPlaybackProgress : (clip.isPlayed ? 1.0 : 0.0);

    final amplitudes = clip.amplitudes.isEmpty ? [0.5] : clip.amplitudes;
    final List<double> barHeights = List.generate(24, (i) {
      final sampleIdx = ((i / 24) * amplitudes.length).floor().clamp(0, amplitudes.length - 1);
      final amp = amplitudes[sampleIdx];
      final wave = 0.2 + 0.8 * (0.6 * amp + 0.4 * sin(i * 0.75).abs());
      return wave.clamp(0.15, 1.0);
    });

    return Container(
      width: 230,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isCurrentPlaying
            ? const Color(0xFF0F2942)
            : (clip.isPlayed ? C2Colors.slateCard : const Color(0xFF2A2000)),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrentPlaying
              ? Colors.cyanAccent
              : (clip.isPlayed ? Colors.white24 : Colors.amberAccent),
          width: isCurrentPlaying ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    isCurrentPlaying ? Icons.volume_up : (clip.isPlayed ? Icons.history : Icons.mark_chat_unread),
                    color: isCurrentPlaying ? Colors.cyanAccent : (clip.isPlayed ? Colors.white54 : Colors.amberAccent),
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    clip.senderCallsign,
                    style: TextStyle(
                      color: isCurrentPlaying ? Colors.cyanAccent : Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Text(
                    isCurrentPlaying
                        ? '${_formatDuration(_clipPosition.inSeconds)} / ${_formatDuration(clip.durationSecs)}'
                        : _formatDuration(clip.durationSecs),
                    style: TextStyle(
                      color: isCurrentPlaying ? Colors.cyanAccent : Colors.white54,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => PttAudioService.deleteClip(clip.id),
                    child: const Icon(Icons.close, color: Colors.white38, size: 14),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 4),

          GestureDetector(
            onTap: () => _playRecordedClip(clip),
            child: SizedBox(
              height: 28,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(barHeights.length, (idx) {
                      final barProgress = idx / barHeights.length;
                      final isPassed = progress >= barProgress;

                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 60),
                        width: 3.5,
                        height: 28 * barHeights[idx],
                        decoration: BoxDecoration(
                          color: isPassed
                              ? (isCurrentPlaying ? Colors.cyanAccent : C2Colors.emeraldAccent)
                              : (clip.isPlayed ? Colors.white24 : Colors.amberAccent.withOpacity(0.4)),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      );
                    }),
                  ),
                  if (isCurrentPlaying)
                    Positioned(
                      left: (progress * 200).clamp(0.0, 200.0),
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 2.5,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(2),
                          boxShadow: const [
                            BoxShadow(color: Colors.cyanAccent, blurRadius: 6, spreadRadius: 1),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 4),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${(clip.audioData.length / 1024).toStringAsFixed(1)} KB',
                style: const TextStyle(color: Colors.white38, fontSize: 8),
              ),
              InkWell(
                onTap: () => _playRecordedClip(clip),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: isCurrentPlaying ? Colors.cyanAccent : (clip.isPlayed ? C2Colors.slateCard : Colors.amberAccent),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isCurrentPlaying ? Icons.pause : Icons.play_arrow,
                        color: isCurrentPlaying ? Colors.black : (clip.isPlayed ? Colors.white : Colors.black),
                        size: 12,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isCurrentPlaying ? 'PAUSE' : 'PLAY FILE',
                        style: TextStyle(
                          color: isCurrentPlaying ? Colors.black : (clip.isPlayed ? Colors.white : Colors.black),
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScopeChip(PttTargetScope scope, String label, IconData icon) {
    final isSelected = _pttScope == scope;
    return ChoiceChip(
      avatar: Icon(icon, size: 12, color: isSelected ? Colors.black : Colors.white70),
      label: Text(label, style: TextStyle(color: isSelected ? Colors.black : Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
      selected: isSelected,
      selectedColor: C2Colors.emeraldAccent,
      backgroundColor: const Color(0xFF1E293B),
      onSelected: (val) {
        if (val) {
          setState(() {
            _pttScope = scope;
          });
        }
      },
    );
  }

  Widget _buildActiveCallScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            Icon(
              _isVideoCall ? Icons.videocam : Icons.phone_in_talk,
              color: _isVideoCall ? Colors.cyanAccent : C2Colors.emeraldAccent,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              'ACTIVE ${_isVideoCall ? "VIDEO" : "VOICE"} CALL WITH ${_selectedPeer?.callsign ?? "TARGET"}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            margin: const EdgeInsets.only(right: 16),
            decoration: BoxDecoration(
              color: C2Colors.emeraldAccent.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: C2Colors.emeraldAccent),
            ),
            child: Text(
              _formatDuration(_callDurationSecs),
              style: const TextStyle(
                color: C2Colors.emeraldAccent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isVideoCall ? Colors.cyanAccent : C2Colors.emeraldAccent,
                  width: 2,
                ),
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleAvatar(
                      radius: 50,
                      backgroundColor: const Color(0xFF0F172A),
                      child: Text(
                        _selectedPeer?.callsign.substring(0, min(2, _selectedPeer?.callsign.length ?? 2)) ?? 'OP',
                        style: TextStyle(
                          color: _isVideoCall ? Colors.cyanAccent : C2Colors.emeraldAccent,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _selectedPeer?.callsign ?? 'OPERATOR',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _selectedPeer?.name ?? '',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.graphic_eq,
                            color: _isMuted ? Colors.redAccent : C2Colors.emeraldAccent,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _isMuted
                                ? 'YOUR MIC IS MUTED'
                                : (_isCallConnected ? 'FULL DUPLEX AUDIO CONNECTED' : 'CALLING ${_selectedPeer?.callsign ?? "TARGET"}...'),
                            style: TextStyle(
                              color: _isMuted ? Colors.redAccent : (_isCallConnected ? C2Colors.emeraldAccent : Colors.amberAccent),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              color: Color(0xFF1E293B),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  onPressed: () {
                    setState(() {
                      _isMuted = !_isMuted;
                    });
                  },
                  icon: Icon(_isMuted ? Icons.mic_off : Icons.mic),
                  color: _isMuted ? Colors.redAccent : Colors.white,
                  iconSize: 28,
                  style: IconButton.styleFrom(
                    backgroundColor: _isMuted ? Colors.red.withOpacity(0.2) : Colors.white12,
                    padding: const EdgeInsets.all(14),
                  ),
                ),
                if (_isVideoCall)
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _isCameraOff = !_isCameraOff;
                      });
                    },
                    icon: Icon(_isCameraOff ? Icons.videocam_off : Icons.videocam),
                    color: _isCameraOff ? Colors.redAccent : Colors.cyanAccent,
                    iconSize: 28,
                    style: IconButton.styleFrom(
                      backgroundColor: _isCameraOff ? Colors.red.withOpacity(0.2) : Colors.cyan.withOpacity(0.2),
                      padding: const EdgeInsets.all(14),
                    ),
                  ),
                FloatingActionButton(
                  onPressed: () => _endCall(transmit: true),
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  child: const Icon(Icons.call_end),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showPttSettingsModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.tune, color: Colors.cyanAccent, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'PTT & AUDIO SETTINGS',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12),
                  const SizedBox(height: 10),

                  // Hardware Mic Test
                  const Text('HARDWARE MIC DIAGNOSTICS', style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _micTestStatus.isEmpty ? 'WebRTC Mic Ready' : 'MIC TEST: $_micTestStatus',
                          style: TextStyle(color: _micTestStatus.isNotEmpty ? Colors.amberAccent : Colors.white70, fontSize: 11),
                        ),
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.cyanAccent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        ),
                        icon: Icon(_isTestingMic ? Icons.graphic_eq : Icons.mic_external_on, size: 14),
                        label: Text(_isTestingMic ? 'TESTING...' : 'TEST MIC (3s)', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                        onPressed: _isTestingMic
                            ? null
                            : () {
                                _runHardwareMicTest();
                                setModalState(() {});
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Scope Selection
                  const Text('TRANSMISSION SCOPE', style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildScopeChip(PttTargetScope.direct, 'DIRECT 1:1', Icons.person),
                        const SizedBox(width: 8),
                        _buildScopeChip(PttTargetScope.group, 'SQUAD GROUP', Icons.groups),
                        const SizedBox(width: 8),
                        _buildScopeChip(PttTargetScope.broadcast, 'BROADCAST', Icons.campaign),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Reception Mode
                  const Text('PTT RECEPTION MODE', style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      ChoiceChip(
                        label: const Text('AUTO-PLAY LIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                        selected: _autoPlayPtt,
                        selectedColor: C2Colors.emeraldAccent,
                        labelStyle: TextStyle(color: _autoPlayPtt ? Colors.black : Colors.white70),
                        onSelected: (val) {
                          _saveAutoPlaySetting(true);
                          setModalState(() {});
                          setState(() {});
                        },
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('PLAY LATER', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                        selected: !_autoPlayPtt,
                        selectedColor: Colors.amberAccent,
                        labelStyle: TextStyle(color: !_autoPlayPtt ? Colors.black : Colors.white70),
                        onSelected: (val) {
                          _saveAutoPlaySetting(false);
                          setModalState(() {});
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Audio Output Device
                  const Text('AUDIO OUTPUT DEVICE', style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      ChoiceChip(
                        avatar: Icon(Icons.volume_up, size: 12, color: _useLoudspeaker ? Colors.black : Colors.white70),
                        label: const Text('LOUDSPEAKER (DEFAULT)', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                        selected: _useLoudspeaker,
                        selectedColor: C2Colors.emeraldAccent,
                        labelStyle: TextStyle(color: _useLoudspeaker ? Colors.black : Colors.white70),
                        onSelected: (val) {
                          _saveAudioOutputSetting(true);
                          setModalState(() {});
                          setState(() {});
                        },
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        avatar: Icon(Icons.phone_in_talk, size: 12, color: !_useLoudspeaker ? Colors.black : Colors.white70),
                        label: const Text('INTERNAL EARPIECE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                        selected: !_useLoudspeaker,
                        selectedColor: Colors.amberAccent,
                        labelStyle: TextStyle(color: !_useLoudspeaker ? Colors.black : Colors.white70),
                        onSelected: (val) {
                          _saveAudioOutputSetting(false);
                          setModalState(() {});
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Audio Codec Profile & Bandwidth
                  const Text('AUDIO CODEC & BANDWIDTH PROFILE', style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        ChoiceChip(
                          label: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: const [
                                Text('NARROWBAND', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                Text('12 kbps | 8 kHz BW (~1.5 KB/s)', style: TextStyle(fontSize: 8)),
                              ],
                            ),
                          ),
                          selected: _codecProfile == PttCodecProfile.narrowband,
                          selectedColor: Colors.amberAccent,
                          labelStyle: TextStyle(color: _codecProfile == PttCodecProfile.narrowband ? Colors.black : Colors.white70),
                          onSelected: (val) {
                            _saveCodecProfile(PttCodecProfile.narrowband);
                            setModalState(() {});
                            setState(() {});
                          },
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: const [
                                Text('STANDARD VOICE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                Text('24 kbps | 11 kHz BW (~3.0 KB/s)', style: TextStyle(fontSize: 8)),
                              ],
                            ),
                          ),
                          selected: _codecProfile == PttCodecProfile.standard,
                          selectedColor: C2Colors.emeraldAccent,
                          labelStyle: TextStyle(color: _codecProfile == PttCodecProfile.standard ? Colors.black : Colors.white70),
                          onSelected: (val) {
                            _saveCodecProfile(PttCodecProfile.standard);
                            setModalState(() {});
                            setState(() {});
                          },
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: const [
                                Text('WIDEBAND HD', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                Text('64 kbps | 24 kHz BW (~8.0 KB/s)', style: TextStyle(fontSize: 8)),
                              ],
                            ),
                          ),
                          selected: _codecProfile == PttCodecProfile.wideband,
                          selectedColor: Colors.purpleAccent,
                          labelStyle: TextStyle(color: _codecProfile == PttCodecProfile.wideband ? Colors.black : Colors.white70),
                          onSelected: (val) {
                            _saveCodecProfile(PttCodecProfile.wideband);
                            setModalState(() {});
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
