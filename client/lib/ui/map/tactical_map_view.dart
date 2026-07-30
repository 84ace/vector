import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../models/operator_profile.dart';
import '../../models/telemetry.dart';
import '../../models/tactical_waypoint.dart';
import '../../models/vector_target.dart';
import '../../models/arcgis_layer.dart';
import '../theme/c2_colors.dart';
import 'profile_marker.dart';
import 'vectoring_tool.dart';
import 'arcgis_layer_panel.dart';
import 'map_focus_controller.dart';
import 'offscreen_member_layer.dart';

enum MapTileTheme { darkVector, satellite, topoTerrain }

class TacticalMapView extends StatefulWidget {
  final OperatorProfile myProfile;
  final Telemetry? myTelemetry;
  final List<OperatorProfile> teamProfiles;
  final Map<String, Telemetry> teamTelemetry;
  final Map<String, List<Telemetry>> teamBreadcrumbs;
  final bool isMeshConnected;
  final bool isP2pConnected;
  final String activeNodeId;
  final int p2pPeersCount;
  final Function(OperatorProfile)? onStartVoiceCall;
  final Function(OperatorProfile)? onStartVideoCall;
  final Function(OperatorProfile)? onOpenChat;
  final String? activeSosOperatorCallsign;

  /// Raises the distress beacon. Lives on the map because this is the screen
  /// that already carries position and situational awareness.
  final VoidCallback? onTriggerSos;

  /// Carries "show me this operator" requests in from the squad list.
  final MapFocusController? focusController;

  /// Opens the network diagnostics screen. The connection pill is where an
  /// operator looks first when something is wrong, so it is also where the
  /// detail behind it belongs.
  final VoidCallback? onShowDiagnostics;

  const TacticalMapView({
    super.key,
    required this.myProfile,
    this.myTelemetry,
    required this.teamProfiles,
    required this.teamTelemetry,
    required this.teamBreadcrumbs,
    required this.isMeshConnected,
    required this.isP2pConnected,
    required this.activeNodeId,
    required this.p2pPeersCount,
    this.onStartVoiceCall,
    this.onStartVideoCall,
    this.onOpenChat,
    this.activeSosOperatorCallsign,
    this.onTriggerSos,
    this.focusController,
    this.onShowDiagnostics,
  });

  @override
  State<TacticalMapView> createState() => _TacticalMapViewState();
}

class _TacticalMapViewState extends State<TacticalMapView> {
  final MapController _mapController = MapController();
  MapTileTheme _currentMapTheme = MapTileTheme.darkVector;

  VectorResult? _activeVector;
  final List<TacticalWaypoint> _customWaypoints = [];
  final List<ArcGISLayer> _activeArcGISLayers = [];

  String get _tileUrlTemplate {
    switch (_currentMapTheme) {
      case MapTileTheme.darkVector:
        return 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';
      case MapTileTheme.satellite:
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
      case MapTileTheme.topoTerrain:
        return 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png';
    }
  }

  bool _hasInitialCentered = false;

  /// The operator the camera is following, if any.
  ///
  /// Locking is deliberately sticky: it survives panning, because a lock that
  /// broke the moment a finger brushed the map would be useless while moving.
  /// The banner across the top is the way out of it.
  String? _lockedOperatorId;

  /// Where the locked operator was when we last moved the camera, so an
  /// unchanged position report does not re-issue a move every rebuild.
  LatLng? _lastTrackedPosition;

  @override
  void initState() {
    super.initState();
    if (widget.myTelemetry != null && widget.myTelemetry!.latitude != 0.0) {
      _hasInitialCentered = true;
    }
    widget.focusController?.addListener(_handleFocusRequest);
  }

  @override
  void dispose() {
    widget.focusController?.removeListener(_handleFocusRequest);
    super.dispose();
  }

  @override
  void didUpdateWidget(TacticalMapView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.focusController != widget.focusController) {
      oldWidget.focusController?.removeListener(_handleFocusRequest);
      widget.focusController?.addListener(_handleFocusRequest);
    }

    if (!_hasInitialCentered && widget.myTelemetry != null && widget.myTelemetry!.latitude != 0.0) {
      _hasInitialCentered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.move(
          LatLng(widget.myTelemetry!.latitude, widget.myTelemetry!.longitude),
          16.0,
        );
      });
      return;
    }

    _followLockedOperator();
  }

  /// Keeps the camera on the locked operator as their reports arrive.
  ///
  /// The zoom the operator has chosen is preserved rather than reset, so
  /// pinching in to read terrain around a tracked member does not get undone by
  /// their next position report four seconds later.
  void _followLockedOperator() {
    final locked = _lockedOperatorId;
    if (locked == null) return;

    final tele = _telemetryForOperatorId(locked);
    if (tele == null || tele.latitude == 0.0 || tele.longitude == 0.0) return;

    final target = LatLng(tele.latitude, tele.longitude);
    final previous = _lastTrackedPosition;
    if (previous != null &&
        previous.latitude == target.latitude &&
        previous.longitude == target.longitude) {
      return;
    }

    _lastTrackedPosition = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _lockedOperatorId != locked) return;
      _mapController.move(target, _mapController.camera.zoom);
    });
  }

  void _handleFocusRequest() {
    final request = widget.focusController?.pending;
    if (request == null) return;
    widget.focusController!.consume();

    final tele = _telemetryForOperatorId(request.operatorId);
    if (tele == null || tele.latitude == 0.0 || tele.longitude == 0.0) {
      // Nothing to centre on. Say so rather than moving to the null island.
      final profile = _profileForOperatorId(request.operatorId);
      final who = profile?.callsign ?? 'OPERATOR';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.amberAccent,
            duration: const Duration(seconds: 3),
            content: Text(
              'NO POSITION REPORTED BY $who YET',
              style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
            ),
          ),
        );
      }
      return;
    }

    setState(() {
      if (request.lock) {
        _lockedOperatorId = request.operatorId;
        _lastTrackedPosition = null;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final zoom = _mapController.camera.zoom;
      _mapController.move(
        LatLng(tele.latitude, tele.longitude),
        zoom < 15.0 ? 16.0 : zoom,
      );
    });
  }

  /// Resolves telemetry for an operator, tolerating the ID/callsign mismatch
  /// that position reports have historically arrived with.
  Telemetry? _telemetryForOperatorId(String operatorId) {
    final direct = widget.teamTelemetry[operatorId];
    if (direct != null) return direct;

    final profile = _profileForOperatorId(operatorId);
    if (profile == null) return null;
    return _telemetryForProfile(profile);
  }

  Telemetry? _telemetryForProfile(OperatorProfile peer) {
    return widget.teamTelemetry[peer.id] ??
        widget.teamTelemetry[peer.callsign] ??
        widget.teamTelemetry.values.cast<Telemetry?>().firstWhere(
              (t) =>
                  t != null &&
                  (t.operatorId.toUpperCase() == peer.id.toUpperCase() ||
                      t.operatorId.toUpperCase() == peer.callsign.toUpperCase()),
              orElse: () => null,
            );
  }

  OperatorProfile? _profileForOperatorId(String operatorId) {
    for (final p in widget.teamProfiles) {
      if (p.id == operatorId || p.callsign.toUpperCase() == operatorId.toUpperCase()) {
        return p;
      }
    }
    return null;
  }

  /// Every paired member we hold a usable fix for, used by both the markers and
  /// the off-screen edge indicators so the two can never disagree about who is
  /// on the map.
  List<MemberFix> _memberFixes() {
    final fixes = <MemberFix>[];
    for (final peer in widget.teamProfiles) {
      if (peer.id == widget.myProfile.id) continue;
      final tele = _telemetryForProfile(peer);
      if (tele == null || tele.latitude == 0.0 || tele.longitude == 0.0) continue;
      fixes.add(MemberFix(peer, tele));
    }
    return fixes;
  }

  void _disengageLock() {
    setState(() {
      _lockedOperatorId = null;
      _lastTrackedPosition = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final LatLng? myPos = (widget.myTelemetry != null && widget.myTelemetry!.latitude != 0.0)
        ? LatLng(widget.myTelemetry!.latitude, widget.myTelemetry!.longitude)
        : null;

    final initialCenter = myPos ?? const LatLng(0.0, 0.0);
    final initialZoom = myPos != null ? 16.0 : 3.0;

    final memberFixes = _memberFixes();
    final lockedFix = _lockedOperatorId == null
        ? null
        : memberFixes.cast<MemberFix?>().firstWhere(
              (f) =>
                  f!.profile.id == _lockedOperatorId ||
                  f.profile.callsign.toUpperCase() == _lockedOperatorId!.toUpperCase(),
              orElse: () => null,
            );

    return Scaffold(
      body: Stack(
        children: [
          // FlutterMap 3D Canvas
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: initialZoom,
              minZoom: 2.0,
              maxZoom: 18.0,
              onLongPress: (tapPosition, point) {
                _showAddWaypointDialog(point);
              },
            ),
            children: [
              // Base Map Tile Layer
              TileLayer(
                urlTemplate: _tileUrlTemplate,
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.vector.c2',
                retinaMode: RetinaMode.isHighDensity(context),
              ),

              // Active ArcGIS Operational Overlay Layers
              for (final layer in _activeArcGISLayers.where((l) => l.isVisible))
                TileLayer(
                  urlTemplate: layer.url,
                  userAgentPackageName: 'com.vector.c2',
                ),

              // Breadcrumb Trails Layer
              PolylineLayer(
                polylines: _buildBreadcrumbPolylines(),
              ),

              // Active Vectoring Target Line
              if (_activeVector != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [
                        LatLng(_activeVector!.fromLat, _activeVector!.fromLng),
                        LatLng(_activeVector!.toLat, _activeVector!.toLng),
                      ],
                      strokeWidth: 3.0,
                      color: Colors.cyanAccent,
                    ),
                  ],
                ),

              // Custom Tactical Waypoints Layer
              MarkerLayer(
                markers: _buildWaypointMarkers(),
              ),

              // Profile Photo Markers Layer
              MarkerLayer(
                markers: _buildProfileMarkers(myPos, memberFixes),
              ),

              // Members who are off the edge of the viewport, kept on screen as
              // chevrons so panning away never loses them entirely.
              OffscreenMemberLayer(
                members: memberFixes,
                myPosition: myPos,
                lockedOperatorId: _lockedOperatorId,
                onTap: (profile) {
                  final tele = _telemetryForProfile(profile);
                  if (tele == null) return;
                  _mapController.move(
                    LatLng(tele.latitude, tele.longitude),
                    _mapController.camera.zoom,
                  );
                },
              ),
            ],
          ),

          // SOS Distress Alert Banner (High Priority)
          if (widget.activeSosOperatorCallsign != null)
            Positioned(
              top: 45,
              left: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(color: Colors.redAccent.withValues(alpha: 0.6), blurRadius: 16, spreadRadius: 4),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.white, size: 24),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'EMERGENCY SOS DISTRESS SIGNAL: ${widget.activeSosOperatorCallsign}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Top Status Bar Overlay (Connection Pill + Layer Switchers)
          Positioned(
            top: widget.activeSosOperatorCallsign != null ? 100 : 50,
            left: 12,
            right: 12,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: _buildConnectionStatusPill(),
                ),
                const SizedBox(width: 8),

                // Single Unified Tactical Layer Management Button
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A).withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.5)),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.layers, color: Colors.cyanAccent, size: 20),
                    tooltip: 'Tactical Map & Overlay Layers',
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: Colors.transparent,
                        isScrollControlled: true,
                        builder: (ctx) => TacticalLayerPanel(
                          currentTheme: _currentMapTheme,
                          onThemeChanged: (theme) {
                            setState(() {
                              _currentMapTheme = theme;
                            });
                          },
                          layers: _activeArcGISLayers,
                          onAddLayer: (layer) {
                            setState(() {
                              _activeArcGISLayers.add(layer);
                            });
                          },
                          onToggleLayer: (layer) {
                            setState(() {});
                          },
                          onDeleteLayer: (layer) {
                            setState(() {
                              _activeArcGISLayers.remove(layer);
                            });
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // Tracking banner. Present only while a lock is engaged, and it is
          // the documented way out of one.
          if (lockedFix != null)
            Positioned(
              top: (widget.activeSosOperatorCallsign != null ? 100 : 50) + 46,
              left: 12,
              right: 12,
              child: _buildTrackingBanner(lockedFix, myPos),
            ),

          // Vectoring Metrics Panel Overlay
          if (_activeVector != null)
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: VectoringToolWidget(
                vector: _activeVector!,
                onClose: () {
                  setState(() {
                    _activeVector = null;
                  });
                },
              ),
            ),

          // Map controls: recenter, and the distress beacon beneath it.
          Positioned(
            right: 12,
            bottom: _activeVector != null ? 140 : 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'fab_my_loc',
                  backgroundColor: const Color(0xFF0F172A),
                  foregroundColor: Colors.cyanAccent,
                  tooltip: 'Centre on my position',
                  onPressed: () {
                    if (myPos != null) {
                      _mapController.move(myPos, 16.0);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          backgroundColor: Colors.amberAccent,
                          duration: Duration(seconds: 2),
                          content: Text('ACQUIRING GPS FIX...', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                        ),
                      );
                    }
                  },
                  child: const Icon(Icons.my_location),
                ),
                if (widget.onTriggerSos != null) ...[
                  const SizedBox(height: 12),
                  // Deliberately separated from the other controls and clearly
                  // labelled: this broadcasts a distress beacon to the whole
                  // squad, and it used to sit in the navigation bar where a
                  // mis-tap could reach it.
                  FloatingActionButton.extended(
                    heroTag: 'fab_sos',
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    icon: const Icon(Icons.warning_amber_rounded),
                    label: const Text('SOS', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                    onPressed: widget.onTriggerSos,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Polyline> _buildBreadcrumbPolylines() {
    List<Polyline> lines = [];
    widget.teamBreadcrumbs.forEach((opId, history) {
      if (history.length >= 2) {
        final points = history.map((t) => LatLng(t.latitude, t.longitude)).toList();
        lines.add(
          Polyline(
            points: points,
            strokeWidth: 2.0,
            color: Colors.cyanAccent.withValues(alpha: 0.4),
          ),
        );
      }
    });
    return lines;
  }

  List<Marker> _buildWaypointMarkers() {
    return _customWaypoints.map((wp) {
      return Marker(
        width: 36,
        height: 36,
        point: LatLng(wp.latitude, wp.longitude),
        child: GestureDetector(
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: C2Colors.slateCard,
                content: Text(
                  'WAYPOINT: ${wp.name} (${wp.type.name.toUpperCase()})',
                  style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
                ),
              ),
            );
          },
          child: Container(
            decoration: BoxDecoration(
              color: Colors.amber,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: const Icon(Icons.location_on, color: Colors.black, size: 20),
          ),
        ),
      );
    }).toList();
  }

  /// The banner shown while the camera is following an operator.
  ///
  /// Carries range and bearing as well as the identity, because "locked onto
  /// BRAVO" without a range does not answer the question that made the operator
  /// lock on in the first place.
  Widget _buildTrackingBanner(MemberFix fix, LatLng? myPos) {
    String detail = 'FOLLOWING POSITION REPORTS';
    if (myPos != null) {
      const geo = Distance();
      final metres = geo.as(LengthUnit.Meter, myPos, fix.position);
      final vec = VectorResult.calculate(
        targetName: fix.profile.callsign,
        fromLat: myPos.latitude,
        fromLng: myPos.longitude,
        fromAlt: widget.myTelemetry?.altitude ?? 0.0,
        toLat: fix.position.latitude,
        toLng: fix.position.longitude,
        toAlt: fix.telemetry.altitude,
        currentSpeedMps: widget.myTelemetry?.speed ?? 0.0,
        currentCompassHeading: widget.myTelemetry?.heading ?? 0.0,
      );
      final range = metres < 1000
          ? '${metres.round()}m'
          : '${(metres / 1000).toStringAsFixed(1)}km';
      detail = '$range · ${vec.azimuthDegrees.toStringAsFixed(0)}° · '
          '${fix.telemetry.isStale ? 'FIX OVERDUE' : 'FIX CURRENT'}';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.cyanAccent),
        boxShadow: [
          BoxShadow(color: Colors.cyanAccent.withValues(alpha: 0.25), blurRadius: 12),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.gps_fixed, color: Colors.cyanAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'TRACKING ${fix.profile.callsign}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: const TextStyle(color: Colors.cyanAccent, fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
            ),
            onPressed: _disengageLock,
            child: const Text(
              'RELEASE',
              style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  List<Marker> _buildProfileMarkers(LatLng? myPos, List<MemberFix> memberFixes) {
    List<Marker> markers = [];

    // 1. My Profile Marker (ONLY if valid location acquired)
    if (myPos != null) {
      markers.add(
        Marker(
          width: 48,
          height: 48,
          point: myPos,
          child: ProfileMarkerWidget(
            profile: widget.myProfile,
            telemetry: widget.myTelemetry,
            isSelected: false,
            onTap: () {},
          ),
        ),
      );
    }

    // 2. Paired Squad Member Markers ONLY (Zero-Trust Privacy)
    for (final fix in memberFixes) {
      markers.add(
        Marker(
          width: 48,
          height: 48,
          point: fix.position,
          child: ProfileMarkerWidget(
            profile: fix.profile,
            telemetry: fix.telemetry,
            isSelected: fix.profile.id == _lockedOperatorId,
            onTap: () {
              _showOperatorContextSheet(fix.profile, fix.telemetry);
            },
          ),
        ),
      );
    }

    return markers;
  }

  void _showOperatorContextSheet(OperatorProfile target, Telemetry targetTele) {
    showModalBottomSheet(
      context: context,
      backgroundColor: C2Colors.slateCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: const Color(0xFF0F172A),
                    child: Text(target.callsign.substring(0, 2), style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(target.callsign, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                      Text(target.name, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ],
              ),
              const Divider(color: Colors.white12, height: 24),
              if (_lockedOperatorId == target.id)
                ListTile(
                  leading: const Icon(Icons.gps_off, color: Colors.redAccent),
                  title: const Text('RELEASE TRACKING LOCK', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _disengageLock();
                  },
                )
              else
                ListTile(
                  leading: const Icon(Icons.gps_fixed, color: Colors.cyanAccent),
                  title: const Text('LOCK ON & TRACK', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                  subtitle: const Text('Camera follows their position reports', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _lockedOperatorId = target.id;
                      _lastTrackedPosition = null;
                    });
                    _mapController.move(
                      LatLng(targetTele.latitude, targetTele.longitude),
                      _mapController.camera.zoom < 15.0 ? 16.0 : _mapController.camera.zoom,
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.radar, color: Colors.cyanAccent),
                title: const Text('VECTOR TO TARGET (BEARING & RANGE)', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(ctx);
                  _selectTargetForVectoring(target, targetTele);
                },
              ),
              ListTile(
                leading: const Icon(Icons.phone, color: C2Colors.emeraldAccent),
                title: const Text('VOICE CALL', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onStartVoiceCall?.call(target);
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam, color: Colors.purpleAccent),
                title: const Text('VIDEO CALL', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onStartVideoCall?.call(target);
                },
              ),
              ListTile(
                leading: const Icon(Icons.chat, color: Colors.amberAccent),
                title: const Text('OPEN CHAT', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onOpenChat?.call(target);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAddWaypointDialog(LatLng position) {
    final nameController = TextEditingController();
    WaypointType selectedType = WaypointType.rallyPoint;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: C2Colors.slateCard,
          title: const Text('DROP TACTICAL WAYPOINT', style: TextStyle(color: Colors.cyanAccent, fontSize: 14, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  hintText: 'Waypoint Label (e.g. Rally Point Alpha)',
                  hintStyle: TextStyle(color: Colors.white38),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
                ),
              ),
              const SizedBox(height: 16),
              StatefulBuilder(
                builder: (context, setDialogState) {
                  return DropdownButton<WaypointType>(
                    value: selectedType,
                    dropdownColor: C2Colors.slateCard,
                    isExpanded: true,
                    items: WaypointType.values.map((t) {
                      return DropdownMenuItem(
                        value: t,
                        child: Text(t.name.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 12)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setDialogState(() => selectedType = val);
                    },
                  );
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCEL', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
              onPressed: () {
                if (nameController.text.isNotEmpty) {
                  setState(() {
                    _customWaypoints.add(
                      TacticalWaypoint(
                        id: 'wp-${DateTime.now().millisecondsSinceEpoch}',
                        name: nameController.text.toUpperCase(),
                        type: selectedType,
                        latitude: position.latitude,
                        longitude: position.longitude,
                        createdByCallsign: widget.myProfile.callsign,
                        timestamp: DateTime.now(),
                      ),
                    );
                  });
                  Navigator.pop(ctx);
                }
              },
              child: const Text('DROP PIN', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _selectTargetForVectoring(OperatorProfile target, Telemetry targetTele) {
    if (widget.myTelemetry == null || widget.myTelemetry!.latitude == 0.0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('GPS FIX REQUIRED FOR VECTORING CALCULATIONS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      );
      return;
    }

    final double myLat = widget.myTelemetry!.latitude;
    final double myLng = widget.myTelemetry!.longitude;
    final double myAlt = widget.myTelemetry?.altitude ?? 0.0;
    final double mySpeed = widget.myTelemetry?.speed ?? 0.0;
    final double myHeading = widget.myTelemetry?.heading ?? 0.0;

    final vec = VectorResult.calculate(
      targetName: target.callsign,
      fromLat: myLat,
      fromLng: myLng,
      fromAlt: myAlt,
      toLat: targetTele.latitude,
      toLng: targetTele.longitude,
      toAlt: targetTele.altitude,
      currentSpeedMps: mySpeed,
      currentCompassHeading: myHeading,
    );

    setState(() {
      _activeVector = vec;
    });
  }

  Widget _buildConnectionStatusPill() {
    String label = 'OFFLINE / DISCONNECTED';
    Color color = Colors.redAccent;

    final hasMesh = widget.isMeshConnected;
    final hasP2P = widget.isP2pConnected;

    if (hasMesh && hasP2P) {
      label = 'MESH & P2P ACTIVE (${widget.activeNodeId} | ${widget.p2pPeersCount} P2P PEERS)';
      color = C2Colors.emeraldAccent;
    } else if (hasMesh) {
      label = 'LOCAL MESH CONNECTED (${widget.activeNodeId})';
      color = C2Colors.emeraldAccent;
    } else if (hasP2P) {
      label = 'DIRECT P2P CONNECTION (${widget.p2pPeersCount} PEERS)';
      color = Colors.cyanAccent;
    }

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.circle,
            size: 8,
            color: color,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
          if (widget.onShowDiagnostics != null) ...[
            const SizedBox(width: 4),
            const Icon(Icons.info_outline, size: 12, color: Colors.white38),
          ],
        ],
      ),
    );

    if (widget.onShowDiagnostics == null) return pill;

    // The pill is the first thing an operator looks at when comms are wrong, so
    // it is the natural handle for the detail behind it.
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: widget.onShowDiagnostics,
      child: pill,
    );
  }
}
