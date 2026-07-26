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

  @override
  void initState() {
    super.initState();
    if (widget.myTelemetry != null && widget.myTelemetry!.latitude != 0.0) {
      _hasInitialCentered = true;
    }
  }

  @override
  void didUpdateWidget(TacticalMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_hasInitialCentered && widget.myTelemetry != null && widget.myTelemetry!.latitude != 0.0) {
      _hasInitialCentered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.move(
          LatLng(widget.myTelemetry!.latitude, widget.myTelemetry!.longitude),
          16.0,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final LatLng? myPos = (widget.myTelemetry != null && widget.myTelemetry!.latitude != 0.0)
        ? LatLng(widget.myTelemetry!.latitude, widget.myTelemetry!.longitude)
        : null;

    final initialCenter = myPos ?? const LatLng(0.0, 0.0);
    final initialZoom = myPos != null ? 16.0 : 3.0;

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
                markers: _buildProfileMarkers(myPos),
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
                  color: Colors.red.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(color: Colors.redAccent.withOpacity(0.6), blurRadius: 16, spreadRadius: 4),
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
                    color: const Color(0xFF0F172A).withOpacity(0.9),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.cyanAccent.withOpacity(0.5)),
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

          // Map Action Buttons (Recenter)
          Positioned(
            right: 12,
            bottom: _activeVector != null ? 140 : 24,
            child: FloatingActionButton.small(
              heroTag: 'fab_my_loc',
              backgroundColor: const Color(0xFF0F172A),
              foregroundColor: Colors.cyanAccent,
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
            color: Colors.cyanAccent.withOpacity(0.4),
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

  List<Marker> _buildProfileMarkers(LatLng? myPos) {
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

    // 2. Team Member Markers from all active team telemetry updates
    final Map<String, OperatorProfile> knownProfiles = {};
    for (final p in widget.teamProfiles) {
      knownProfiles[p.id] = p;
    }

    widget.teamTelemetry.forEach((opId, tele) {
      if (opId == widget.myProfile.id) return;
      if (tele.latitude == 0.0 || tele.longitude == 0.0) return;

      final profile = knownProfiles[opId] ??
          widget.teamProfiles.firstWhere(
            (p) => p.id == opId || p.callsign.toUpperCase() == opId.toUpperCase(),
            orElse: () {
              final cleanCallsign = opId.startsWith('op-')
                  ? opId.replaceFirst('op-', '').split('-').first.toUpperCase()
                  : opId.toUpperCase();
              return OperatorProfile(
                id: opId,
                callsign: cleanCallsign.isNotEmpty ? cleanCallsign : 'OPERATOR',
                name: 'Squad Member',
                role: OperatorRole.operator,
                avatarBase64: '',
                publicKey: '',
                lastSeen: tele.timestamp,
                isOnline: !tele.isOffline,
              );
            },
          );

      markers.add(
        Marker(
          width: 48,
          height: 48,
          point: LatLng(tele.latitude, tele.longitude),
          child: ProfileMarkerWidget(
            profile: profile,
            telemetry: tele,
            isSelected: false,
            onTap: () {
              _showOperatorContextSheet(profile, tele);
            },
          ),
        ),
      );
    });

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
                title: const Text('INITIATE E2EE VOICE CALL', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onStartVoiceCall?.call(target);
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam, color: Colors.purpleAccent),
                title: const Text('INITIATE E2EE VIDEO CALL', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onStartVideoCall?.call(target);
                },
              ),
              ListTile(
                leading: const Icon(Icons.chat, color: Colors.amberAccent),
                title: const Text('OPEN SECURE E2EE CHAT', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.9),
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
        ],
      ),
    );
  }
}
