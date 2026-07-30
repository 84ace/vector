import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../models/operator_profile.dart';
import '../../models/telemetry.dart';
import '../theme/c2_colors.dart';

/// A squad member and the position they last reported.
@immutable
class MemberFix {
  final OperatorProfile profile;
  final Telemetry telemetry;

  const MemberFix(this.profile, this.telemetry);

  LatLng get position => LatLng(telemetry.latitude, telemetry.longitude);
}

/// Pins squad members who are outside the viewport to the edge of the map,
/// pointing at where they actually are.
///
/// Panning or zooming in used to lose an operator completely: their marker left
/// the screen and the map gave no clue which way to pan back, so finding a
/// member again meant zooming out until they reappeared and then working back
/// in. A chevron on the edge keeps every member on screen in the only sense
/// that matters in the field — direction and range — without the map having to
/// zoom out far enough to render them all properly.
///
/// This is a child of [FlutterMap], so it reads the live camera and re-lays
/// itself out on every pan and zoom.
class OffscreenMemberLayer extends StatelessWidget {
  final List<MemberFix> members;

  /// Used for the range readout. Omitted when this device has no fix, because
  /// "1.2km" from an unknown origin is worse than no number at all.
  final LatLng? myPosition;

  final String? lockedOperatorId;
  final void Function(OperatorProfile) onTap;

  /// How far in from the map edge the chevrons sit. Enough to clear the status
  /// pill along the top and the controls down the right.
  static const double _inset = 58.0;

  const OffscreenMemberLayer({
    super.key,
    required this.members,
    required this.onTap,
    this.myPosition,
    this.lockedOperatorId,
  });

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final width = camera.nonRotatedSize.x;
    final height = camera.nonRotatedSize.y;

    // Before the first layout the camera reports an impossible size; placing
    // anything against it would throw or flash a row of chevrons in the corner.
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return const SizedBox.shrink();
    }

    final centre = Offset(width / 2, height / 2);
    final indicators = <Widget>[];

    for (final member in members) {
      final screen = camera.latLngToScreenPoint(member.position);
      if (!screen.x.isFinite || !screen.y.isFinite) continue;

      final offset = Offset(screen.x, screen.y);

      // Anything already comfortably on screen has a real marker drawn for it.
      // The margin is deliberately larger than the inset so a member does not
      // get both a marker and a chevron at the same time.
      final onScreen = offset.dx >= _inset &&
          offset.dx <= width - _inset &&
          offset.dy >= _inset &&
          offset.dy <= height - _inset;
      if (onScreen) continue;

      final edge = _clampToEdge(offset - centre, width, height);
      if (edge == null) continue;

      indicators.add(
        Positioned(
          left: centre.dx + edge.dx - 26,
          top: centre.dy + edge.dy - 26,
          width: 52,
          height: 52,
          child: _EdgeChevron(
            member: member,
            screenAngle: atan2(edge.dy, edge.dx),
            range: _range(member.position),
            isLocked: member.profile.id == lockedOperatorId,
            onTap: () => onTap(member.profile),
          ),
        ),
      );
    }

    if (indicators.isEmpty) return const SizedBox.shrink();

    // The map's own gestures have to keep working everywhere the chevrons are
    // not, so this cannot be an opaque full-size Stack.
    return IgnorePointer(
      ignoring: false,
      child: Stack(children: indicators),
    );
  }

  /// Scales [v] — a vector from the viewport centre — until it lands on the
  /// inset viewport rectangle, so the chevron sits on the edge nearest the
  /// member rather than in a corner.
  Offset? _clampToEdge(Offset v, double width, double height) {
    final halfW = width / 2 - _inset;
    final halfH = height / 2 - _inset;
    if (halfW <= 0 || halfH <= 0) return null;

    // A member projecting exactly onto the centre cannot be off screen, but
    // guard anyway: the division below would produce infinity.
    if (v.dx.abs() < 0.001 && v.dy.abs() < 0.001) return null;

    final scaleX = v.dx.abs() < 0.001 ? double.infinity : halfW / v.dx.abs();
    final scaleY = v.dy.abs() < 0.001 ? double.infinity : halfH / v.dy.abs();
    final scale = min(scaleX, scaleY);
    if (!scale.isFinite) return null;

    return v * scale;
  }

  String? _range(LatLng target) {
    final me = myPosition;
    if (me == null) return null;
    const geo = Distance();
    final metres = geo.as(LengthUnit.Meter, me, target);
    if (metres < 1000) return '${metres.round()}m';
    if (metres < 10000) return '${(metres / 1000).toStringAsFixed(1)}km';
    return '${(metres / 1000).round()}km';
  }
}

/// One edge chevron: an arrow pointing off screen, the callsign, and the range.
class _EdgeChevron extends StatelessWidget {
  final MemberFix member;

  /// Direction from the viewport centre to the member, in screen space.
  final double screenAngle;

  final String? range;
  final bool isLocked;
  final VoidCallback onTap;

  const _EdgeChevron({
    required this.member,
    required this.screenAngle,
    required this.range,
    required this.isLocked,
    required this.onTap,
  });

  Color get _statusColour {
    if (isLocked) return Colors.cyanAccent;
    if (member.telemetry.isOffline) return C2Colors.offlineGrey;
    if (member.telemetry.isStale) return C2Colors.warningAmber;
    return C2Colors.emeraldAccent;
  }

  @override
  Widget build(BuildContext context) {
    final colour = _statusColour;
    final label = member.profile.callsign;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Icons.navigation points north; the angle is measured from east.
          Transform.rotate(
            angle: screenAngle + pi / 2,
            child: Icon(
              Icons.navigation,
              size: 26,
              color: colour,
              shadows: const [
                Shadow(color: Colors.black87, blurRadius: 4),
              ],
            ),
          ),
          const SizedBox(height: 1),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: colour, width: 0.8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label.length > 6 ? label.substring(0, 6) : label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),
                if (range != null)
                  Text(
                    range!,
                    style: TextStyle(
                      color: colour,
                      fontSize: 7,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
