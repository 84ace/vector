import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/c2_message.dart';
import '../../services/ptt_audio_service.dart';
import '../theme/c2_colors.dart';

/// A push-to-talk transmission, playable in the conversation it belongs to.
///
/// Replaces the horizontal clip strip on the old Voice tab. Voice and text are
/// the same conversation, so a transmission belongs in the thread next to the
/// messages around it rather than in a separate inbox that lost all context of
/// who said what, when.
class VoiceMessageBubble extends StatelessWidget {
  final C2Message message;
  final Color accent;
  final bool mine;

  const VoiceMessageBubble({
    super.key,
    required this.message,
    required this.accent,
    required this.mine,
  });

  /// Decodes the transmission carried by [message], or null if it is not one.
  static ({Uint8List audio, Duration duration})? payloadOf(C2Message message) {
    final body = message.decryptedBody ?? '';
    if (!body.startsWith('PTT_STOP:')) return null;

    try {
      final data = jsonDecode(body.substring('PTT_STOP:'.length)) as Map<String, dynamic>;
      final encoded = data['audio_base64'] as String?;
      if (encoded == null || encoded.isEmpty) return null;

      return (
        audio: base64Decode(encoded),
        duration: Duration(milliseconds: (data['duration_ms'] as num?)?.toInt() ?? 0),
      );
    } catch (_) {
      return null;
    }
  }

  /// Deterministic bars from the message ID, so a clip looks the same every
  /// time it is drawn without decoding the audio to measure it.
  List<double> _bars() {
    final seed = message.id.hashCode;
    final rnd = Random(seed);
    return List<double>.generate(22, (i) {
      final envelope = sin((i / 22) * pi);
      return (0.25 + 0.75 * envelope * (0.5 + rnd.nextDouble() * 0.5)).clamp(0.15, 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final payload = payloadOf(message);
    if (payload == null) {
      return Text(
        'Voice transmission (unavailable)',
        style: TextStyle(color: Colors.white38, fontSize: 12),
      );
    }

    final clipId = message.id;
    final bars = _bars();

    return ValueListenableBuilder<String?>(
      valueListenable: PttAudioService.playingClipId,
      builder: (context, playingId, _) {
        final isPlaying = playingId == clipId;

        return ValueListenableBuilder<Duration>(
          valueListenable: PttAudioService.playbackPosition,
          builder: (context, position, child) {
            return ValueListenableBuilder<Duration>(
              valueListenable: PttAudioService.playbackDuration,
              builder: (context, reported, child) {
                final total = isPlaying && reported > Duration.zero
                    ? reported
                    : payload.duration;
                final progress = isPlaying && total.inMilliseconds > 0
                    ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
                    : 0.0;

                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _playButton(clipId, payload, isPlaying),
                    const SizedBox(width: 10),
                    _waveform(bars, progress, isPlaying),
                    const SizedBox(width: 10),
                    Text(
                      _clock(isPlaying ? position : total),
                      style: TextStyle(
                        color: isPlaying ? accent : Colors.white38,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _playButton(
    String clipId,
    ({Uint8List audio, Duration duration}) payload,
    bool isPlaying,
  ) {
    return Semantics(
      button: true,
      label: isPlaying ? 'Stop voice transmission' : 'Play voice transmission',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => PttAudioService.playClip(
          clipId,
          payload.audio,
          known: payload.duration,
        ),
        child: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent.withValues(alpha: 0.22),
            border: Border.all(color: accent, width: 1.2),
          ),
          child: Icon(
            isPlaying ? Icons.stop : Icons.play_arrow,
            color: accent,
            size: 18,
          ),
        ),
      ),
    );
  }

  Widget _waveform(List<double> bars, double progress, bool isPlaying) {
    return SizedBox(
      width: 110,
      height: 26,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < bars.length; i++)
            Container(
              width: 2.5,
              height: 26 * bars[i],
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: (i / bars.length) <= progress && isPlaying
                    ? accent
                    : (mine ? Colors.white38 : C2Colors.slateCard.withValues(alpha: 0.9)),
              ),
            ),
        ],
      ),
    );
  }

  static String _clock(Duration d) {
    final secs = d.inSeconds;
    return '${(secs ~/ 60).toString().padLeft(2, '0')}:${(secs % 60).toString().padLeft(2, '0')}';
  }
}
