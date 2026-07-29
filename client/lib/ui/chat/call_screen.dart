import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoView, RTCVideoViewObjectFit;

import '../../models/operator_profile.dart';
import '../../services/webrtc_call_service.dart';
import '../theme/c2_colors.dart';

/// The full-screen call UI: dialling, ringing, and connected.
///
/// Extracted from CallView, which had grown to hold push-to-talk, the clip
/// strip, audio settings and the call screens all at once. Everything here is
/// driven by [WebRtcCallService], so it can be rendered and exercised without
/// standing up the rest of the voice page.
class CallScreen extends StatelessWidget {
  final WebRtcCallService service;
  final OperatorProfile? fallbackPeer;

  /// Seconds the call has been connected, formatted by the parent's timer.
  final int callDurationSecs;

  /// Whether audio is routed to the loudspeaker, and how to change that.
  final bool useLoudspeaker;
  final ValueChanged<bool> onLoudspeakerChanged;
  final VoidCallback onHangUp;

  const CallScreen({
    super.key,
    required this.service,
    required this.fallbackPeer,
    required this.callDurationSecs,
    required this.useLoudspeaker,
    required this.onLoudspeakerChanged,
    required this.onHangUp,
  });

  @override
  Widget build(BuildContext context) => service.state == CallState.connected
      ? _buildActiveCallScreen()
      : _buildCallingScreen();

  static String _formatDuration(int totalSecs) {
    final mins = totalSecs ~/ 60;
    final secs = totalSecs % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  Widget _buildCallingScreen() {
        final peer = service.peerProfile ?? fallbackPeer;
    final isIncoming = service.state == CallState.ringing;

    final label = switch (service.state) {
      CallState.dialing => 'CALLING',
      CallState.ringing => 'INCOMING ${service.isVideo ? "VIDEO" : "VOICE"} CALL',
      CallState.connecting => 'CONNECTING',
      _ => 'CALLING',
    };

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            CircleAvatar(
              radius: 56,
              backgroundColor: const Color(0xFF1E293B),
              child: Text(
                (peer?.callsign ?? 'OP').substring(0, min(2, peer?.callsign.length ?? 2)),
                style: TextStyle(
                  color: service.isVideo ? Colors.cyanAccent : C2Colors.emeraldAccent,
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              peer?.callsign ?? 'OPERATOR',
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: service.isVideo ? Colors.cyanAccent : C2Colors.emeraldAccent,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'End-to-end encrypted',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(bottom: 48),
              child: Row(
                mainAxisAlignment: isIncoming
                    ? MainAxisAlignment.spaceEvenly
                    : MainAxisAlignment.center,
                children: [
                  _callActionButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    label: isIncoming ? 'DECLINE' : 'CANCEL',
                    onPressed: () =>
                        isIncoming ? service.declineCall() : service.hangUp(),
                  ),
                  if (isIncoming)
                    _callActionButton(
                      icon: service.isVideo ? Icons.videocam : Icons.call,
                      color: C2Colors.emeraldAccent,
                      label: 'ANSWER',
                      onPressed: service.acceptCall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _callActionButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 68,
          height: 68,
          child: FloatingActionButton(
            heroTag: 'call_$label',
            backgroundColor: color,
            foregroundColor: Colors.white,
            onPressed: onPressed,
            child: Icon(icon, size: 30),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  /// The connected call. Video calls render both streams; voice calls show the
  /// peer's callsign and the running duration.
  Widget _buildActiveCallScreen() {
        final peer = service.peerProfile ?? fallbackPeer;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: service.isVideo
                  ? RTCVideoView(
                      service.remoteRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : _buildVoiceCallBackdrop(peer),
            ),

            // Local preview, only meaningful on a video call.
            if (service.isVideo && !service.isCameraOff)
              Positioned(
                top: 16,
                right: 16,
                width: 110,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: RTCVideoView(
                    service.localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),

            // Header: who, and how long.
            Positioned(
              top: 16,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      peer?.callsign ?? 'OPERATOR',
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.lock, color: C2Colors.emeraldAccent, size: 11),
                        const SizedBox(width: 4),
                        Text(
                          _formatDuration(callDurationSecs),
                          style: const TextStyle(color: C2Colors.emeraldAccent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Controls.
            Positioned(
              left: 0,
              right: 0,
              bottom: 32,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _callToggle(
                    icon: service.isMuted ? Icons.mic_off : Icons.mic,
                    active: service.isMuted,
                    tooltip: service.isMuted ? 'Unmute' : 'Mute',
                    onPressed: () => service.toggleMute(),
                  ),
                  if (service.isVideo) ...[
                    const SizedBox(width: 14),
                    _callToggle(
                      icon: service.isCameraOff ? Icons.videocam_off : Icons.videocam,
                      active: service.isCameraOff,
                      tooltip: service.isCameraOff ? 'Camera on' : 'Camera off',
                      onPressed: () => service.toggleCamera(),
                    ),
                    const SizedBox(width: 14),
                    _callToggle(
                      icon: Icons.cameraswitch,
                      active: false,
                      tooltip: 'Switch camera',
                      onPressed: service.switchCamera,
                    ),
                  ],
                  const SizedBox(width: 14),
                  _callToggle(
                    icon: useLoudspeaker ? Icons.volume_up : Icons.hearing,
                    active: false,
                    tooltip: useLoudspeaker ? 'Speaker' : 'Earpiece',
                    onPressed: () => onLoudspeakerChanged(!useLoudspeaker),
                  ),
                  const SizedBox(width: 14),
                  SizedBox(
                    width: 62,
                    height: 62,
                    child: FloatingActionButton(
                      heroTag: 'call_hangup',
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      onPressed: onHangUp,
                      child: const Icon(Icons.call_end, size: 28),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceCallBackdrop(OperatorProfile? peer) {
    return Container(
      color: const Color(0xFF0F172A),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 60,
              backgroundColor: const Color(0xFF1E293B),
              child: Text(
                (peer?.callsign ?? 'OP').substring(0, min(2, peer?.callsign.length ?? 2)),
                style: const TextStyle(
                  color: C2Colors.emeraldAccent,
                  fontSize: 38,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              peer?.callsign ?? 'OPERATOR',
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _callToggle({
    required IconData icon,
    required bool active,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? Colors.redAccent.withValues(alpha: 0.85) : Colors.white24,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }
}
