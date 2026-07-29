import 'package:flutter/material.dart';

import '../../models/c2_message.dart';
import '../../models/telemetry.dart';
import '../../services/ptt_recorder.dart';
import '../../services/secure_channel.dart';
import '../../services/webrtc_call_service.dart';
import '../chat/audience_selector.dart';
import '../theme/c2_colors.dart';
import 'voice_message_bubble.dart';

/// A single conversation: messages, voice, and the ways to reach this audience.
///
/// One screen per contact or channel. Previously the same conversation was
/// split across a Comms tab (text, behind an audience selector) and a Voice tab
/// (push-to-talk, behind a second audience selector), with calls started from a
/// third place. The four ways of reaching someone now sit together, and the
/// screen you are on *is* the audience — there is nothing to select.
class ConversationView extends StatefulWidget {
  final Audience audience;
  final List<C2Message> messages;
  final Telemetry? telemetry;
  final SecureChannel channel;
  final PttRecorder ptt;

  final Future<void> Function(String text) onSendText;

  /// Called when a push-to-talk transmission finishes, so the shell can file it
  /// into the conversation the same way a received one is filed.
  final Future<void> Function(Audience audience, Duration duration, List<int> audio)?
      onVoiceRecorded;
  final void Function(CallMedia media)? onStartCall;
  final VoidCallback? onShowDetails;

  const ConversationView({
    super.key,
    required this.audience,
    required this.messages,
    required this.channel,
    required this.ptt,
    required this.onSendText,
    this.onVoiceRecorded,
    this.telemetry,
    this.onStartCall,
    this.onShowDetails,
  });

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<C2Message> get _visible => widget.messages
      .where((m) =>
          widget.audience.includes(m, widget.channel.myOperatorId) &&
          Audience.isDisplayableContent(m))
      .toList();

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && _scroll.position.hasContentDimensions) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    try {
      await widget.onSendText(text);
      _input.clear();
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final audience = widget.audience;
    final canCall = audience.isDirect && widget.onStartCall != null;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              audience.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Row(
              children: [
                Icon(Icons.lock, color: audience.accent, size: 9),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    _subtitle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: audience.accent, fontSize: 10),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (canCall)
            IconButton(
              icon: const Icon(Icons.call, color: C2Colors.emeraldAccent),
              tooltip: 'Voice call ${audience.label}',
              onPressed: () => widget.onStartCall!(CallMedia.voice),
            ),
          if (canCall)
            IconButton(
              icon: const Icon(Icons.videocam, color: Colors.cyanAccent),
              tooltip: 'Video call ${audience.label}',
              onPressed: () => widget.onStartCall!(CallMedia.video),
            ),
          if (widget.onShowDetails != null)
            IconButton(
              icon: const Icon(Icons.more_vert, color: Colors.white54),
              tooltip: 'Details',
              onPressed: widget.onShowDetails,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildThread()),
          ValueListenableBuilder<bool>(
            valueListenable: widget.ptt.isTransmitting,
            builder: (context, transmitting, _) {
              if (!transmitting) return const SizedBox.shrink();
              return Container(
                width: double.infinity,
                color: Colors.redAccent.withValues(alpha: 0.9),
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.mic, color: Colors.white, size: 14),
                    const SizedBox(width: 8),
                    Text(
                      'TRANSMITTING TO ${audience.label}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          _buildComposer(),
        ],
      ),
    );
  }

  String _subtitle() {
    if (!widget.audience.isDirect) return widget.audience.assurance;

    final t = widget.telemetry;
    if (t == null) return 'Encrypted · no position yet';
    if (t.isOffline) return 'Encrypted · position lost';
    if (t.isStale) return 'Encrypted · position overdue';
    return 'Encrypted · reporting';
  }

  Widget _buildThread() {
    final messages = _visible;

    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.audience.icon, color: Colors.white12, size: 56),
              const SizedBox(height: 16),
              Text(
                'No messages with ${widget.audience.label} yet',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 6),
              const Text(
                'Type a message, or hold the microphone to talk.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white24, fontSize: 11),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      itemCount: messages.length,
      itemBuilder: (_, i) => _bubble(messages[i]),
    );
  }

  Widget _bubble(C2Message msg) {
    final mine = msg.isMe;
    final body = msg.decryptedBody ?? '';
    final isVoice = body.startsWith('PTT_STOP');

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? Colors.cyan.withValues(alpha: 0.18) : C2Colors.slateCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: mine ? Colors.cyanAccent.withValues(alpha: 0.4) : Colors.white12,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine && !widget.audience.isDirect)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  msg.senderId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.audience.accent,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            if (isVoice)
              VoiceMessageBubble(
                message: msg,
                accent: mine ? Colors.cyanAccent : widget.audience.accent,
                mine: mine,
              )
            else
              Text(body, style: const TextStyle(color: Colors.white, fontSize: 13)),
            const SizedBox(height: 3),
            Text(
              _clock(msg.timestamp),
              style: const TextStyle(color: Colors.white24, fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _buildComposer() {
    final hasText = _input.text.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      color: const Color(0xFF1E293B),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                textInputAction: TextInputAction.send,
                minLines: 1,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: 'Message ${widget.audience.label}...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                ),
              ),
            ),
            // Send appears only when there is something to send. The
            // microphone is always present: on this app voice is the primary
            // mode, and it should never be the control that disappears.
            if (hasText) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.send, color: _sending ? Colors.white24 : widget.audience.accent),
                tooltip: 'Send to ${widget.audience.label}',
                onPressed: _sending ? null : _send,
              ),
            ],
            const SizedBox(width: 4),
            _buildPttButton(),
          ],
        ),
      ),
    );
  }

  /// Hold to talk.
  ///
  /// Sized and coloured as the primary action: the earlier version was a faint
  /// white-on-white icon beside a bright send button, which read as absent.
  Widget _buildPttButton() {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.ptt.isTransmitting,
      builder: (context, transmitting, _) {
        final accent = widget.audience.accent;

        return GestureDetector(
          onTapDown: (_) => widget.ptt.start(widget.audience),
          onTapUp: (_) => _stopPtt(),
          onTapCancel: _stopPtt,
          child: Tooltip(
            message: 'Hold to talk to ${widget.audience.label}',
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: transmitting ? Colors.redAccent : accent.withValues(alpha: 0.18),
                border: Border.all(
                  color: transmitting ? Colors.redAccent : accent,
                  width: transmitting ? 2.5 : 1.5,
                ),
                boxShadow: transmitting
                    ? [
                        BoxShadow(
                          color: Colors.redAccent.withValues(alpha: 0.55),
                          blurRadius: 18,
                          spreadRadius: 3,
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                transmitting ? Icons.mic : Icons.mic_none,
                color: transmitting ? Colors.white : accent,
                size: 26,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _stopPtt() async {
    final clip = await widget.ptt.stop(widget.audience);
    if (clip != null) {
      await widget.onVoiceRecorded?.call(
        widget.audience,
        clip.duration,
        clip.audioData,
      );
    }
    if (mounted) _scrollToBottom();
  }
}
