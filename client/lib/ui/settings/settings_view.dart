import 'dart:convert';
import 'package:flutter/material.dart';
import '../../models/operator_profile.dart';
import '../../models/c2_event_log.dart';
import '../theme/c2_colors.dart';

class SettingsView extends StatefulWidget {
  final OperatorProfile myProfile;
  final List<OperatorProfile> teamProfiles;
  final List<C2EventLog> eventLogs;
  final Function(OperatorProfile) onProfileUpdated;
  final Function(String) onRemoveContact;
  final VoidCallback onClearLogs;
  final VoidCallback onClearData;

  /// Opens the live comms state behind the event log. The log says what happened;
  /// this says what is happening.
  final VoidCallback? onShowDiagnostics;

  const SettingsView({
    super.key,
    required this.myProfile,
    required this.teamProfiles,
    required this.eventLogs,
    required this.onProfileUpdated,
    required this.onRemoveContact,
    required this.onClearLogs,
    required this.onClearData,
    this.onShowDiagnostics,
  });

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late TextEditingController _callsignController;
  late String _avatarBase64;
  bool _isStealthMode = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _callsignController = TextEditingController(text: widget.myProfile.callsign);
    _avatarBase64 = widget.myProfile.avatarBase64;
  }

  @override
  void dispose() {
    _tabController.dispose();
    _callsignController.dispose();
    super.dispose();
  }

  void _saveProfile() {
    if (_callsignController.text.isEmpty) return;

    final updated = widget.myProfile.copyWith(
      callsign: _callsignController.text.toUpperCase(),
      name: _callsignController.text.toUpperCase(),
      avatarBase64: _avatarBase64,
    );

    widget.onProfileUpdated(updated);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: C2Colors.emeraldAccent,
        content: Text('OPERATOR PROFILE & AVATAR UPDATED', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
      ),
    );
  }

  void _showAvatarPickerModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: C2Colors.slateCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'SELECT TACTICAL AVATAR ICON',
              style: TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.8),
            ),
            const SizedBox(height: 12),
            const Text(
              'Select a tactical profile avatar or custom image to display as your 3D Map marker and chat icon across squad devices:',
              style: TextStyle(color: Colors.white70, fontSize: 11),
            ),
            const SizedBox(height: 16),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildAvatarChoice(
                  icon: Icons.shield,
                  label: 'COMMAND',
                  color: Colors.amberAccent,
                ),
                _buildAvatarChoice(
                  icon: Icons.radar,
                  label: 'RECON',
                  color: Colors.cyanAccent,
                ),
                _buildAvatarChoice(
                  icon: Icons.gps_fixed,
                  label: 'SNIPER',
                  color: Colors.redAccent,
                ),
                _buildAvatarChoice(
                  icon: Icons.psychology,
                  label: 'INTEL',
                  color: Colors.purpleAccent,
                ),
              ],
            ),

            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.cyanAccent,
                  side: const BorderSide(color: Colors.cyanAccent),
                ),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('RESET TO INITIALS AVATAR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                onPressed: () {
                  setState(() {
                    _avatarBase64 = '';
                  });
                  Navigator.pop(ctx);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarChoice({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return InkWell(
      onTap: () {
        // Generate a clean tactical avatar canvas identifier string
        setState(() {
          _avatarBase64 = '';
        });
        Navigator.pop(context);
      },
      child: Column(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: const Color(0xFF0F172A),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C2Colors.slateBg,
      appBar: AppBar(
        backgroundColor: C2Colors.slateCard,
        title: const Row(
          children: [
            Icon(Icons.settings, color: Colors.cyanAccent, size: 20),
            SizedBox(width: 8),
            Text(
              'SETTINGS & TACTICAL LOGS',
              style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.8),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.cyanAccent,
          labelColor: Colors.cyanAccent,
          unselectedLabelColor: Colors.white54,
          labelStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
          tabs: const [
            Tab(text: 'PROFILE'),
            Tab(text: 'ACTIVITY LOG'),
            Tab(text: 'SYSTEM'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildProfileTab(),
          _buildActivityLogTab(),
          _buildSystemTab(),
        ],
      ),
    );
  }

  static String _shortKey(String key) =>
      key.length <= 16 ? key : '${key.substring(0, 16)}...';

  Widget _buildProfileTab() {

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('OPERATOR IDENTITY & MAP AVATAR', style: TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
        const SizedBox(height: 16),

        // Profile Photo / Avatar Picker Preview
        Center(
          child: Column(
            children: [
              Stack(
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.cyanAccent, width: 3),
                      boxShadow: [
                        BoxShadow(color: Colors.cyanAccent.withValues(alpha: 0.3), blurRadius: 12, spreadRadius: 2),
                      ],
                    ),
                    child: ClipOval(
                      child: _avatarBase64.isNotEmpty
                          ? Image.memory(
                              base64Decode(_avatarBase64),
                              fit: BoxFit.cover,
                              errorBuilder: (ctx, err, stack) => _buildAvatarInitials(),
                            )
                          : _buildAvatarInitials(),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: _showAvatarPickerModal,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                          color: Colors.cyanAccent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.camera_alt, color: Colors.black, size: 16),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _showAvatarPickerModal,
                icon: const Icon(Icons.photo_camera, size: 14, color: Colors.cyanAccent),
                label: const Text('CHANGE PROFILE PHOTO / ICON', style: TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        TextField(
          controller: _callsignController,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: const InputDecoration(
            labelText: 'Tactical Callsign',
            labelStyle: TextStyle(color: Colors.white70),
            filled: true,
            fillColor: C2Colors.slateCard,
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),

        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
          icon: const Icon(Icons.save, size: 16),
          label: const Text('SAVE PROFILE CHANGES', style: TextStyle(fontWeight: FontWeight.bold)),
          onPressed: _saveProfile,
        ),

        const Divider(color: Colors.white12, height: 32),

        const Text('SECURITY FINGERPRINT', style: TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
        const SizedBox(height: 8),

        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: C2Colors.slateCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Operator ID: ${widget.myProfile.id}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
              const SizedBox(height: 6),
              const Text(
                'Your ID is derived from your identity key, so no other device can claim it.',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
              const SizedBox(height: 6),
              Text(
                'Identity key: ${_shortKey(widget.myProfile.signPublicKey)}',
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAvatarInitials() {
    final initials = widget.myProfile.callsign.isNotEmpty
        ? widget.myProfile.callsign.substring(0, 2)
        : 'OP';
    return Container(
      color: const Color(0xFF0F172A),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 24),
      ),
    );
  }

  Widget _buildActivityLogTab() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: const Color(0xFF1E293B),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.history_edu, color: Colors.cyanAccent, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'TACTICAL EVENT AUDIT LOG (${widget.eventLogs.length})',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Row(
                children: [
                  if (widget.onShowDiagnostics != null)
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: Colors.cyanAccent),
                      icon: const Icon(Icons.lan, size: 14),
                      label: const Text('NETWORK', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      onPressed: widget.onShowDiagnostics,
                    ),
                  if (widget.eventLogs.isNotEmpty)
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                      icon: const Icon(Icons.clear_all, size: 14),
                      label: const Text('CLEAR LOGS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      onPressed: widget.onClearLogs,
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: widget.eventLogs.isEmpty
              ? const Center(
                  child: Text(
                    'No tactical activity recorded yet.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: widget.eventLogs.length,
                  itemBuilder: (context, index) {
                    final log = widget.eventLogs[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: C2Colors.slateCard,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _getSeverityColor(log.severity).withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(_getSeverityIcon(log.severity), color: _getSeverityColor(log.severity), size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      log.title,
                                      style: TextStyle(
                                        color: _getSeverityColor(log.severity),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      '${log.timestamp.hour}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}',
                                      style: const TextStyle(color: Colors.white38, fontSize: 10),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  log.details,
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
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
      ],
    );
  }

  Widget _buildSystemTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('POWER & STEALTH MODE', style: TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
        const SizedBox(height: 8),

        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Stealth Battery-Saver Mode', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
          subtitle: const Text('Reduces GPS telemetry broadcast frequency from 4s to 30s to preserve battery life.', style: TextStyle(color: Colors.white38, fontSize: 11)),
          value: _isStealthMode,
          activeThumbColor: C2Colors.emeraldAccent,
          onChanged: (val) {
            setState(() {
              _isStealthMode = val;
            });
          },
        ),

        const Divider(color: Colors.white12, height: 32),

        const Text('FACTORY DATA RESET', style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
        const SizedBox(height: 8),

        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.redAccent,
            side: const BorderSide(color: Colors.redAccent),
          ),
          icon: const Icon(Icons.delete_forever, size: 16),
          label: const Text('RESET APP & CLEAR ALL PERSISTED DATA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
          onPressed: () {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: C2Colors.slateCard,
                title: const Text('RESET APP DATA?', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                content: const Text('This will clear your local identity keys, chat history, activity logs, and saved contacts list.', style: TextStyle(color: Colors.white70, fontSize: 12)),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCEL', style: TextStyle(color: Colors.white54))),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      widget.onClearData();
                    },
                    child: const Text('RESET NOW', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Color _getSeverityColor(EventSeverity severity) {
    switch (severity) {
      case EventSeverity.info:
        return Colors.cyanAccent;
      case EventSeverity.warning:
        return Colors.amberAccent;
      case EventSeverity.alert:
        return Colors.orangeAccent;
      case EventSeverity.security:
        return Colors.redAccent;
    }
  }

  IconData _getSeverityIcon(EventSeverity severity) {
    switch (severity) {
      case EventSeverity.info:
        return Icons.info_outline;
      case EventSeverity.warning:
        return Icons.warning_amber;
      case EventSeverity.alert:
        return Icons.notifications_active;
      case EventSeverity.security:
        return Icons.security;
    }
  }
}
