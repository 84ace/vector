import 'package:flutter/material.dart';
import '../../models/vector_target.dart';
import '../theme/c2_colors.dart';

class VectoringToolWidget extends StatelessWidget {
  final VectorResult vector;
  final VoidCallback onClose;

  const VectoringToolWidget({
    super.key,
    required this.vector,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.cyanAccent.withValues(alpha: 0.2),
            blurRadius: 12,
            spreadRadius: 2,
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.radar, color: Colors.cyanAccent, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'VECTOR -> ${vector.targetName.toUpperCase()}',
                    style: const TextStyle(
                      color: Colors.cyanAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      letterSpacing: 1.0,
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: onClose,
              ),
            ],
          ),
          const Divider(color: Colors.white24, height: 16),

          // Metrics Grid
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildMetricTile(
                label: 'DISTANCE',
                value: vector.formattedDistance,
                icon: Icons.straighten,
                accentColor: C2Colors.emeraldAccent,
              ),
              _buildMetricTile(
                label: 'BEARING',
                value: vector.formattedAzimuth,
                icon: Icons.explore,
                accentColor: Colors.cyanAccent,
              ),
              _buildMetricTile(
                label: 'REL. HEADING',
                value: '${vector.relativeHeadingDegrees.toStringAsFixed(0)}°',
                icon: Icons.turn_right,
                accentColor: Colors.amberAccent,
              ),
              _buildMetricTile(
                label: 'EST. TIME',
                value: vector.formattedETA,
                icon: Icons.timer,
                accentColor: Colors.purpleAccent,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricTile({
    required String label,
    required String value,
    required IconData icon,
    required Color accentColor,
  }) {
    return Column(
      children: [
        Icon(icon, color: accentColor, size: 16),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
