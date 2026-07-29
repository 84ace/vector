import 'package:flutter/material.dart';

import '../../models/c2_message.dart';
import '../../models/operator_profile.dart';
import '../theme/c2_colors.dart';

/// Who a transmission is addressed to.
enum AudienceKind { direct, squad, broadcast }

/// The audience for a message or voice transmission.
///
/// One idea, defined once. The app previously expressed this choice four
/// separate times — three tabs on Comms, a peer-selector chip row, a scope
/// selector buried in the Voice settings modal, and a second peer-selector row
/// beside it — in two different visual languages, with nothing keeping them in
/// step.
class Audience {
  final AudienceKind kind;

  /// The recipient, for [AudienceKind.direct] only.
  final OperatorProfile? peer;

  const Audience._(this.kind, this.peer);

  const Audience.squad() : this._(AudienceKind.squad, null);
  const Audience.broadcast() : this._(AudienceKind.broadcast, null);
  const Audience.direct(OperatorProfile peer) : this._(AudienceKind.direct, peer);

  bool get isDirect => kind == AudienceKind.direct;

  /// Whether this audience can actually be transmitted to right now.
  bool get isDeliverable => !isDirect || peer != null;

  MessageType get messageType => switch (kind) {
        AudienceKind.direct => MessageType.chat1to1,
        AudienceKind.squad => MessageType.chatGroup,
        AudienceKind.broadcast => MessageType.broadcast,
      };

  String get label => switch (kind) {
        AudienceKind.direct => peer?.callsign ?? 'DIRECT',
        AudienceKind.squad => 'SQUAD',
        AudienceKind.broadcast => 'ALL',
      };

  /// One line stating who will receive this and how it is protected.
  String get assurance => switch (kind) {
        AudienceKind.direct =>
          'Encrypted to ${peer?.callsign ?? "no one"} — only they can read it',
        AudienceKind.squad => 'Encrypted to your squad',
        AudienceKind.broadcast => 'Encrypted to your squad — everyone will see this',
      };

  Color get accent => switch (kind) {
        AudienceKind.direct => Colors.cyanAccent,
        AudienceKind.squad => C2Colors.emeraldAccent,
        AudienceKind.broadcast => Colors.amberAccent,
      };

  IconData get icon => switch (kind) {
        AudienceKind.direct => Icons.person,
        AudienceKind.squad => Icons.groups,
        AudienceKind.broadcast => Icons.campaign,
      };

  /// Whether [msg] is addressed to this audience.
  ///
  /// A direct conversation carries two envelope types: chat text, and the
  /// call-signalling type that push-to-talk rides on. Admitting only the former
  /// meant a received voice transmission was stored but never displayed —
  /// it simply vanished between arriving and being rendered.
  bool includes(C2Message msg, String myOperatorId) {
    switch (kind) {
      case AudienceKind.direct:
        final id = peer?.id;
        if (id == null) return false;
        if (msg.type != MessageType.chat1to1 &&
            msg.type != MessageType.callSignaling) {
          return false;
        }
        return (msg.senderId == id && msg.recipientId == myOperatorId) ||
            (msg.senderId == myOperatorId && msg.recipientId == id);
      case AudienceKind.squad:
        return msg.type == MessageType.chatGroup;
      case AudienceKind.broadcast:
        return msg.type == MessageType.broadcast;
    }
  }

  /// Whether [msg] is something an operator should see in a conversation.
  ///
  /// Control payloads and call signalling share the conversation envelope
  /// types; only text and completed voice transmissions are content. Defined
  /// once so the thread and the list preview cannot disagree about what counts.
  static bool isDisplayableContent(C2Message msg) {
    final body = msg.decryptedBody ?? '';
    if (body.isEmpty) return false;
    if (body.startsWith('PTT_STOP')) return true; // A finished transmission.

    const control = [
      'DELIVERY_ACK',
      'READ_ACK',
      'UNPAIR_AND_PURGE',
      'PAIR_ACK',
      'PAIR_REQUEST',
      'TEAM_KEY_SYNC',
      'GROUP_REKEY',
      'PTT_START',
      'PTT_AUDIO_CHUNK',
      'CALL_',
    ];
    return !control.any(body.contains);
  }

  @override
  bool operator ==(Object other) =>
      other is Audience && other.kind == kind && other.peer?.id == peer?.id;

  @override
  int get hashCode => Object.hash(kind, peer?.id);
}

/// Picks the audience for the screen it sits on.
///
/// Deliberately always visible rather than tucked into a menu: on the Voice
/// page the equivalent control lived inside a settings modal, so an operator
/// could hold the transmit button with no indication that their voice was
/// going to the entire squad.
class AudienceSelector extends StatelessWidget {
  final List<OperatorProfile> contacts;
  final Audience value;
  final ValueChanged<Audience> onChanged;

  /// Hides the assurance line where space is tight.
  final bool showAssurance;

  const AudienceSelector({
    super.key,
    required this.contacts,
    required this.value,
    required this.onChanged,
    this.showAssurance = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'TO',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _directChip(context),
                      const SizedBox(width: 8),
                      _kindChip(const Audience.squad()),
                      const SizedBox(width: 8),
                      _kindChip(const Audience.broadcast()),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (showAssurance) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.lock, color: value.accent, size: 11),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    value.assurance,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: value.accent, fontSize: 10),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// The direct chip doubles as the peer picker: tapping it when already
  /// selected opens the contact list, so choosing a recipient does not need a
  /// second row of controls.
  Widget _directChip(BuildContext context) {
    final selected = value.isDirect;
    final peer = value.peer ?? (contacts.isNotEmpty ? contacts.first : null);
    final enabled = contacts.isNotEmpty;

    return _chip(
      label: peer?.callsign ?? 'NO CONTACTS',
      icon: Icons.person,
      accent: Colors.cyanAccent,
      selected: selected,
      enabled: enabled,
      trailing: contacts.length > 1 ? Icons.arrow_drop_down : null,
      onTap: () async {
        if (!enabled) return;
        if (!selected || contacts.length == 1) {
          onChanged(Audience.direct(peer!));
          if (contacts.length == 1 || !selected) return;
        }
        final chosen = await showModalBottomSheet<OperatorProfile>(
          context: context,
          backgroundColor: const Color(0xFF0F172A),
          showDragHandle: true,
          isScrollControlled: true,
          builder: (ctx) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'SEND TO',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                for (final c in contacts)
                  ListTile(
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: C2Colors.slateCard,
                      child: Text(
                        c.callsign.substring(0, c.callsign.length >= 2 ? 2 : 1),
                        style: const TextStyle(
                          color: Colors.cyanAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      c.callsign,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    trailing: c.id == value.peer?.id
                        ? const Icon(Icons.check, color: Colors.cyanAccent, size: 18)
                        : null,
                    onTap: () => Navigator.pop(ctx, c),
                  ),
              ],
            ),
          ),
        );
        if (chosen != null) onChanged(Audience.direct(chosen));
      },
    );
  }

  Widget _kindChip(Audience audience) => _chip(
        label: audience.label,
        icon: audience.icon,
        accent: audience.accent,
        selected: value.kind == audience.kind,
        enabled: true,
        onTap: () => onChanged(audience),
      );

  Widget _chip({
    required String label,
    required IconData icon,
    required Color accent,
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
    IconData? trailing,
  }) {
    final colour = !enabled
        ? Colors.white24
        : selected
            ? accent
            : Colors.white54;

    return Material(
      color: selected ? accent.withValues(alpha: 0.18) : const Color(0xFF1E293B),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? accent : Colors.white12,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: colour, size: 14),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: colour,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              if (trailing != null) Icon(trailing, color: colour, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}
