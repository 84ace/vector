import 'package:flutter/material.dart';

import '../../models/c2_message.dart';
import '../../models/operator_profile.dart';
import '../../models/telemetry.dart';
import '../../services/ptt_recorder.dart';
import '../../services/webrtc_call_service.dart';
import '../chat/audience_selector.dart';
import '../theme/c2_colors.dart';

/// One row of the squad list: an operator, or the squad/broadcast channels.
class ConversationSummary {
  final Audience audience;

  /// Straight-line range from this device, when both positions are known.
  final double? distanceMeters;

  /// Live telemetry for a direct conversation, if any has been received.
  final Telemetry? telemetry;

  final C2Message? lastMessage;
  final int unread;
  final int memberCount;

  const ConversationSummary({
    required this.audience,
    this.distanceMeters,
    this.telemetry,
    this.lastMessage,
    this.unread = 0,
    this.memberCount = 0,
  });

  String get title => audience.isDirect ? audience.peer!.callsign : audience.label;
}

/// The squad, as a list of conversations.
///
/// This replaces a roster on one tab and a separate three-tab messaging screen
/// on another, which listed the same operators twice and split "who is on my
/// team" from "talking to them". A row now carries both: where they are, and
/// what they last said.
class ConversationList extends StatelessWidget {
  final List<ConversationSummary> conversations;
  final ValueChanged<Audience> onOpen;
  final ValueChanged<Audience> onShowDetails;
  final VoidCallback onAddOperator;

  /// Push-to-talk straight from the list, without opening the conversation.
  final PttRecorder ptt;
  final Future<void> Function(Audience audience) onVoiceRecorded;
  final void Function(Audience audience, CallMedia media) onStartCall;

  /// Jumps to the map centred on an operator. [lock] additionally engages
  /// tracking, and is raised by a long press on the same control.
  final void Function(OperatorProfile peer, {bool lock})? onLocateOnMap;

  const ConversationList({
    super.key,
    required this.conversations,
    required this.onOpen,
    required this.onShowDetails,
    required this.onAddOperator,
    required this.ptt,
    required this.onVoiceRecorded,
    required this.onStartCall,
    this.onLocateOnMap,
  });

  @override
  Widget build(BuildContext context) {
    final direct = conversations.where((c) => c.audience.isDirect).toList();
    final channels = conversations.where((c) => !c.audience.isDirect).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Row(
          children: [
            Icon(Icons.people_alt, color: Colors.cyanAccent, size: 20),
            SizedBox(width: 8),
            Text(
              'SQUAD',
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
            icon: const Icon(Icons.person_add, color: Colors.cyanAccent),
            tooltip: 'Add operator',
            onPressed: onAddOperator,
          ),
        ],
      ),
      body: direct.isEmpty ? _emptyState() : ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          for (final c in direct) _row(context, c),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              'CHANNELS',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ),
          for (final c in channels) _row(context, c),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, ConversationSummary c) {
    final accent = c.audience.accent;

    return InkWell(
      onTap: () => onOpen(c.audience),
      onLongPress: c.audience.isDirect ? () => onShowDetails(c.audience) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _avatar(c, accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _statusChip(c),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(child: _preview(c)),
                      if (c.unread > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.cyanAccent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${c.unread}',
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (c.telemetry != null) ...[
                    const SizedBox(height: 4),
                    _stats(c),
                  ],
                  const SizedBox(height: 6),
                  _actions(c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// At-a-glance condition of the far end: how far, how much battery, how it
  /// is connected, and how fresh the fix is.
  ///
  /// These arrive in every position report and were previously only visible by
  /// opening a details sheet, which is too slow to be useful when the question
  /// is "can they reach me and are they still up".
  Widget _stats(ConversationSummary c) {
    final t = c.telemetry!;
    final battery = t.batteryLevel;

    return Row(
      children: [
        if (c.distanceMeters != null)
          _stat(
            Icons.straighten,
            _range(c.distanceMeters!),
            Colors.cyanAccent,
          ),
        _stat(
          t.isCharging ? Icons.battery_charging_full : _batteryIcon(battery),
          '$battery%',
          battery <= 15
              ? Colors.redAccent
              : battery <= 35
                  ? Colors.amberAccent
                  : C2Colors.emeraldAccent,
        ),
        _stat(
          switch (t.networkType) {
            NetworkType.wifi => Icons.wifi,
            NetworkType.cellular => Icons.signal_cellular_alt,
            NetworkType.offline => Icons.signal_cellular_off,
          },
          t.networkType == NetworkType.offline ? 'NO LINK' : t.networkType.name.toUpperCase(),
          t.networkType == NetworkType.offline ? Colors.white24 : Colors.white54,
        ),
        if (t.accuracy > 0)
          _stat(Icons.gps_fixed, '±${t.accuracy.round()}m', Colors.white38),
      ],
    );
  }

  static IconData _batteryIcon(int level) => switch (level) {
        <= 15 => Icons.battery_alert,
        <= 35 => Icons.battery_3_bar,
        <= 70 => Icons.battery_5_bar,
        _ => Icons.battery_full,
      };

  /// Range in the units an operator reads at a glance.
  static String _range(double metres) {
    if (metres < 1000) return '${metres.round()}m';
    if (metres < 10000) return '${(metres / 1000).toStringAsFixed(1)}km';
    return '${(metres / 1000).round()}km';
  }

  Widget _stat(IconData icon, String value, Color colour) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: colour),
          const SizedBox(width: 3),
          Text(
            value,
            style: TextStyle(color: colour, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  /// Quick actions for a conversation, without opening it.
  ///
  /// Push-to-talk was one tap away when it had its own page; routing everything
  /// through a conversation cost it that immediacy. These put it back, and give
  /// calls the same directness.
  Widget _actions(ConversationSummary c) {
    final audience = c.audience;
    final canCall = audience.isDirect;

    return Row(
      children: [
        _action(
          icon: Icons.chat_bubble_outline,
          tooltip: 'Message ${audience.label}',
          colour: Colors.cyanAccent,
          onTap: () => onOpen(audience),
        ),
        _pttAction(audience),
        if (audience.isDirect && onLocateOnMap != null) _locateAction(c),
        if (canCall)
          _action(
            icon: Icons.call,
            tooltip: 'Voice call ${audience.label}',
            colour: C2Colors.emeraldAccent,
            onTap: () => onStartCall(audience, CallMedia.voice),
          ),
        if (canCall)
          _action(
            icon: Icons.videocam,
            tooltip: 'Video call ${audience.label}',
            colour: Colors.purpleAccent,
            onTap: () => onStartCall(audience, CallMedia.video),
          ),
      ],
    );
  }

  /// Hold to talk, straight from the row.
  ///
  /// Engaged by a long press rather than a plain touch: the row sits in a
  /// scrolling list, and a finger landing here on the way to a scroll must not
  /// open a microphone.
  Widget _pttAction(Audience audience) {
    return ValueListenableBuilder<Audience?>(
      valueListenable: ptt.activeAudience,
      builder: (context, active, _) {
        final live = active == audience;

        return GestureDetector(
          onLongPressStart: (_) => ptt.start(audience),
          onLongPressEnd: (_) => _finishPtt(audience),
          onLongPressCancel: () => _finishPtt(audience),
          child: Tooltip(
            // The tooltip's own long-press recogniser shares this pointer and
            // the same 500 ms deadline. Registered deeper in the tree, it won the
            // arena first and rejected the long press above, so holding this
            // control never opened the microphone at all.
            triggerMode: TooltipTriggerMode.manual,
            message: 'Hold to talk to ${audience.label}',
            child: Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: live ? Colors.redAccent : Colors.white10,
                boxShadow: live
                    ? [BoxShadow(color: Colors.redAccent.withValues(alpha: 0.5), blurRadius: 10, spreadRadius: 1)]
                    : null,
              ),
              child: Icon(
                live ? Icons.mic : Icons.mic_none,
                size: 16,
                color: live ? Colors.white : Colors.amberAccent,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _finishPtt(Audience audience) async {
    if (ptt.activeAudience.value != audience) return;
    await onVoiceRecorded(audience);
  }

  /// Jump to this operator on the map.
  ///
  /// Finding a member used to mean switching to the map and hunting for their
  /// marker, which is the wrong amount of work for the most common question an
  /// operator asks of the roster. A hold engages tracking instead of a one-off
  /// centre, for a member who is moving.
  Widget _locateAction(ConversationSummary c) {
    final peer = c.audience.peer!;
    final hasFix = c.telemetry != null &&
        !(c.telemetry!.latitude == 0.0 && c.telemetry!.longitude == 0.0);

    return Tooltip(
      // Manual: a long-press tooltip would enter the gesture arena and win it
      // off the long-press below, which is what broke push-to-talk.
      triggerMode: TooltipTriggerMode.manual,
      message: hasFix
          ? 'Show ${peer.callsign} on the map — hold to track'
          : '${peer.callsign} has not reported a position',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => onLocateOnMap!(peer, lock: false),
        onLongPress: hasFix ? () => onLocateOnMap!(peer, lock: true) : null,
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.all(6),
          decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white10),
          child: Icon(
            hasFix ? Icons.my_location : Icons.location_disabled,
            size: 16,
            // Greyed rather than hidden: an operator with no fix is information,
            // and a control that comes and goes between rows is harder to hit.
            color: hasFix ? Colors.amberAccent : Colors.white24,
          ),
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String tooltip,
    required Color colour,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.all(6),
          decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white10),
          child: Icon(icon, size: 16, color: colour),
        ),
      ),
    );
  }

  Widget _avatar(ConversationSummary c, Color accent) {
    final label = c.audience.isDirect
        ? c.title.substring(0, c.title.length >= 2 ? 2 : 1)
        : null;

    return CircleAvatar(
      radius: 22,
      backgroundColor: C2Colors.slateCard,
      child: label != null
          ? Text(
              label,
              style: TextStyle(color: accent, fontSize: 13, fontWeight: FontWeight.bold),
            )
          : Icon(c.audience.icon, color: accent, size: 20),
    );
  }

  /// Position freshness for an operator, member count for a channel.
  Widget _statusChip(ConversationSummary c) {
    if (!c.audience.isDirect) {
      return Text(
        c.memberCount > 0 ? '${c.memberCount} MEMBERS' : '',
        style: const TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold),
      );
    }

    final (label, colour) = switch (c.telemetry) {
      null => ('NO POSITION', Colors.white24),
      final t when t.isOffline => ('LOST', Colors.redAccent),
      final t when t.isStale => ('OVERDUE', Colors.amberAccent),
      _ => ('REPORTING', C2Colors.emeraldAccent),
    };

    return Text(
      label,
      style: TextStyle(color: colour, fontSize: 9, fontWeight: FontWeight.bold),
    );
  }

  /// Last thing said, or the last position report if nothing was said.
  Widget _preview(ConversationSummary c) {
    final msg = c.lastMessage;

    if (msg == null) {
      final t = c.telemetry;
      return Text(
        t == null ? 'No messages yet' : 'Position reported ${_age(t.timestamp)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white38, fontSize: 12),
      );
    }

    final body = msg.decryptedBody ?? '';
    final isVoice = body.contains('PTT_STOP');
    final text = isVoice ? 'Voice clip' : body;

    return Row(
      children: [
        if (msg.isMe) ...[
          const Icon(Icons.done_all, color: Colors.white38, size: 12),
          const SizedBox(width: 4),
        ],
        if (isVoice) ...[
          const Icon(Icons.mic, color: Colors.amberAccent, size: 12),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: c.unread > 0 ? Colors.white70 : Colors.white38,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          _age(msg.timestamp),
          style: const TextStyle(color: Colors.white24, fontSize: 10),
        ),
      ],
    );
  }

  static String _age(DateTime when) {
    final d = DateTime.now().difference(when);
    if (d.inSeconds < 60) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.groups_outlined, color: Colors.white24, size: 72),
            const SizedBox(height: 20),
            const Text(
              'NO OPERATORS PAIRED',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Pair with another operator to share position, message and talk. '
              'Scan their code, or show them yours.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              ),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('ADD OPERATOR', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: onAddOperator,
            ),
          ],
        ),
      ),
    );
  }
}
