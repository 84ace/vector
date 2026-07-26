import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../models/operator_profile.dart';
import '../theme/c2_colors.dart';

class OnboardingView extends StatefulWidget {
  final Function(OperatorProfile) onSetupComplete;

  const OnboardingView({
    super.key,
    required this.onSetupComplete,
  });

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  final _formKey = GlobalKey<FormState>();
  final _callsignController = TextEditingController();
  OperatorRole _selectedRole = OperatorRole.operator;

  bool _locationGranted = false;
  bool _micGranted = false;
  bool _cameraGranted = false;

  @override
  void initState() {
    super.initState();
    _checkExistingPermissions();
  }

  Future<void> _checkExistingPermissions() async {
    if (kIsWeb) return;

    if (Platform.isMacOS) {
      // Geolocator supports macOS permission checks natively
      final locPermission = await Geolocator.checkPermission();
      setState(() {
        _locationGranted = locPermission == LocationPermission.always ||
            locPermission == LocationPermission.whileInUse;
        // Microphone/Camera permissions are requested JIT by macOS on stream opening
        _micGranted = true;
        _cameraGranted = true;
      });
    } else {
      // iOS / Android
      final loc = await Permission.location.isGranted;
      final mic = await Permission.microphone.isGranted;
      final cam = await Permission.camera.isGranted;
      if (mounted) {
        setState(() {
          _locationGranted = loc;
          _micGranted = mic;
          _cameraGranted = cam;
        });
      }
    }
  }

  Future<void> _requestLocation() async {
    if (Platform.isMacOS) {
      final permission = await Geolocator.requestPermission();
      setState(() {
        _locationGranted = permission == LocationPermission.always ||
            permission == LocationPermission.whileInUse;
      });
    } else {
      final status = await Permission.location.request();
      setState(() {
        _locationGranted = status.isGranted;
      });
    }
  }

  Future<void> _requestMicrophone() async {
    if (Platform.isMacOS) {
      // macOS requests permission when mic stream is opened
      setState(() {
        _micGranted = true;
      });
    } else {
      final status = await Permission.microphone.request();
      setState(() {
        _micGranted = status.isGranted;
      });
    }
  }

  Future<void> _requestCamera() async {
    if (Platform.isMacOS) {
      // macOS requests permission when camera stream is opened
      setState(() {
        _cameraGranted = true;
      });
    } else {
      final status = await Permission.camera.request();
      setState(() {
        _cameraGranted = status.isGranted;
      });
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final profile = OperatorProfile(
      id: 'op-${_callsignController.text.toLowerCase()}-${DateTime.now().millisecondsSinceEpoch % 1000}',
      callsign: _callsignController.text.toUpperCase(),
      name: _callsignController.text.toUpperCase(),
      role: _selectedRole,
      avatarBase64: '',
      publicKey: 'pubkey_${_callsignController.text.toLowerCase()}_${DateTime.now().millisecondsSinceEpoch}',
      lastSeen: DateTime.now(),
      isOnline: true,
    );

    widget.onSetupComplete(profile);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C2Colors.slateBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // C2 Logo Header
                const Icon(
                  Icons.shield_outlined,
                  size: 80,
                  color: Colors.cyanAccent,
                ),
                const SizedBox(height: 16),
                const Text(
                  'VECTOR C2 PLATFORM',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2.0,
                  ),
                  textAlign: TextAlign.center,
                ),
                const Text(
                  'Tactical Command & Control Platform',
                  style: TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),

                // Form Fields
                TextFormField(
                  controller: _callsignController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Callsign (e.g. ALPHA-1)',
                    labelStyle: TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.cyanAccent),
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter a callsign';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Role Dropdown
                DropdownButtonFormField<OperatorRole>(
                  value: _selectedRole,
                  dropdownColor: C2Colors.slateCard,
                  decoration: const InputDecoration(
                    labelText: 'Operational Role',
                    labelStyle: TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.cyanAccent),
                    ),
                  ),
                  items: OperatorRole.values.map((role) {
                    return DropdownMenuItem(
                      value: role,
                      child: Text(
                        role.name.toUpperCase(),
                        style: const TextStyle(color: Colors.white),
                      ),
                    );
                  }).toList(),
                  onChanged: (role) {
                    if (role != null) {
                      setState(() {
                        _selectedRole = role;
                      });
                    }
                  },
                ),
                const SizedBox(height: 32),

                // System Permissions Matrix Section
                const Text(
                  'HARDWARE PERMISSIONS',
                  style: TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 8),

                _buildPermissionTile(
                  label: 'High-Accuracy Location Services',
                  description: 'Required for real-time tactical map telemetry',
                  isGranted: _locationGranted,
                  onReq: _requestLocation,
                ),
                _buildPermissionTile(
                  label: 'Microphone & Audio Systems',
                  description: Platform.isMacOS
                      ? 'Will be requested JIT during active calls'
                      : 'Required for Push-To-Talk voice comms',
                  isGranted: _micGranted,
                  onReq: _requestMicrophone,
                ),
                _buildPermissionTile(
                  label: 'Camera Systems',
                  description: Platform.isMacOS
                      ? 'Will be requested JIT during active video streams'
                      : 'Required for video calls & QR contact pairing',
                  isGranted: _cameraGranted,
                  onReq: _requestCamera,
                ),
                const SizedBox(height: 32),

                // Complete Setup Button
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _submit,
                  child: const Text(
                    'INITIALIZE DEVICE & JOIN MESH',
                    style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionTile({
    required String label,
    required String description,
    required bool isGranted,
    required VoidCallback onReq,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        description,
        style: const TextStyle(color: Colors.white38, fontSize: 11),
      ),
      trailing: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: isGranted ? C2Colors.emeraldAccent : Colors.white12,
          foregroundColor: isGranted ? Colors.black : Colors.white,
        ),
        onPressed: isGranted ? null : onReq,
        child: Text(isGranted ? 'GRANTED' : 'GRANT', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
      ),
    );
  }
}
