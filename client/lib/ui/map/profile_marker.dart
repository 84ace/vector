import 'dart:convert';
import 'package:flutter/material.dart';

import '../../models/operator_profile.dart';
import '../../models/telemetry.dart';
import '../theme/c2_colors.dart';

class ProfileMarkerWidget extends StatelessWidget {
  final OperatorProfile profile;
  final Telemetry? telemetry;
  final bool isSelected;
  final VoidCallback onTap;

  const ProfileMarkerWidget({
    super.key,
    required this.profile,
    this.telemetry,
    this.isSelected = false,
    required this.onTap,
  });

  Color get _statusColor {
    if (telemetry == null || telemetry!.isOffline) {
      return C2Colors.offlineGrey;
    }
    if (telemetry!.isStale) {
      return C2Colors.warningAmber;
    }
    return C2Colors.emeraldAccent;
  }

  @override
  Widget build(BuildContext context) {
    final heading = telemetry?.heading ?? 0.0;

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Directional Compass Heading Arrow
          Transform.rotate(
            angle: (heading * 3.141592653589793 / 180),
            child: Icon(
              Icons.navigation,
              size: 48,
              color: _statusColor.withValues(alpha: 0.6),
            ),
          ),

          // Profile Photo Avatar with Border Status Ring
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? Colors.cyanAccent : _statusColor,
                width: isSelected ? 3.5 : 2.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: _statusColor.withValues(alpha: 0.4),
                  blurRadius: isSelected ? 10 : 6,
                  spreadRadius: isSelected ? 3 : 1,
                ),
              ],
            ),
            child: ClipOval(
              child: profile.avatarBase64.isNotEmpty
                  ? Image.memory(
                      base64Decode(profile.avatarBase64),
                      fit: BoxFit.cover,
                      errorBuilder: (ctx, err, stack) => _buildInitialsAvatar(),
                    )
                  : _buildInitialsAvatar(),
            ),
          ),

          // Callsign Tag Pill below avatar
          Positioned(
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _statusColor, width: 1),
              ),
              child: Text(
                profile.callsign,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInitialsAvatar() {
    final initials = profile.callsign.length >= 2
        ? profile.callsign.substring(0, 2).toUpperCase()
        : 'OP';
    return Container(
      color: const Color(0xFF1E293B),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          color: _statusColor,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }
}
