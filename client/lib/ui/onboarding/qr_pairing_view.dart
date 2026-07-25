import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../models/operator_profile.dart';
import '../theme/c2_colors.dart';

class QrPairingView extends StatefulWidget {
  final OperatorProfile myProfile;
  final List<String> meshNodeUrls;
  final Function(OperatorProfile, String tokenId) onContactAdded;

  const QrPairingView({
    super.key,
    required this.myProfile,
    required this.meshNodeUrls,
    required this.onContactAdded,
  });

  @override
  State<QrPairingView> createState() => _QrPairingViewState();
}

class _QrPairingViewState extends State<QrPairingView> {
  final _pairingInputController = TextEditingController();
  late String _currentTokenId;

  @override
  void initState() {
    super.initState();
    _regenerateToken();
  }

  void _regenerateToken() {
    setState(() {
      _currentTokenId = 'tok-${DateTime.now().millisecondsSinceEpoch}-${widget.myProfile.id.hashCode}';
    });
  }

  String get _pairingPayload {
    final payload = {
      'c2_version': '1.0',
      'token_id': _currentTokenId,
      'operator_id': widget.myProfile.id,
      'callsign': widget.myProfile.callsign,
      'name': widget.myProfile.name,
      'public_key': widget.myProfile.publicKey,
      'mesh_nodes': widget.meshNodeUrls,
    };
    return 'c2://pair?data=${base64Encode(utf8.encode(jsonEncode(payload)))}';
  }

  void _copyPairingCode() {
    final payloadToCopy = _pairingPayload;
    Clipboard.setData(ClipboardData(text: payloadToCopy));
    
    // Regenerate new single-use token for next time
    _regenerateToken();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: C2Colors.emeraldAccent,
        duration: Duration(seconds: 3),
        content: Text(
          'SINGLE-USE PAIRING CODE COPIED (NEW CODE GENERATED FOR NEXT USER)',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  void _parseAndAddContact(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) return;

    try {
      if (!text.startsWith('c2://pair?data=')) {
        throw Exception('Invalid scheme');
      }

      final base64Data = text.replaceFirst('c2://pair?data=', '');
      final rawJson = utf8.decode(base64Decode(base64Data));
      final Map<String, dynamic> data = jsonDecode(rawJson);

      final tokenId = data['token_id'] ?? 'legacy-tok';

      final newProfile = OperatorProfile(
        id: data['operator_id'] ?? 'op-${DateTime.now().millisecondsSinceEpoch}',
        callsign: data['callsign'] ?? 'OPERATOR',
        name: data['name'] ?? 'Unknown',
        role: OperatorRole.operator,
        avatarBase64: '',
        publicKey: data['public_key'] ?? '',
        lastSeen: DateTime.now(),
        isOnline: true,
      );

      widget.onContactAdded(newProfile, tokenId);
      _pairingInputController.clear();
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            'INVALID PAIRING CODE. PLEASE ENSURE IT WAS SCANNED/COPIED CORRECTLY.',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _pairingInputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1E293B),
          title: const Row(
            children: [
              Icon(Icons.qr_code_2, color: Colors.cyanAccent, size: 20),
              SizedBox(width: 8),
              Text(
                'SINGLE-USE SECURE SQUAD PAIRING',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          bottom: const TabBar(
            indicatorColor: Colors.cyanAccent,
            labelColor: Colors.cyanAccent,
            unselectedLabelColor: Colors.white54,
            labelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            tabs: [
              Tab(text: 'MY PAIRING CODE'),
              Tab(text: 'SCAN / ENTER CODE'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildMyQrTab(),
            _buildScanTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildMyQrTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.2),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.amberAccent),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.security, color: Colors.amberAccent, size: 14),
                SizedBox(width: 6),
                Text(
                  'SINGLE-USE EXPIRING PAIRING CODE ACTIVE',
                  style: TextStyle(color: Colors.amberAccent, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.cyan.withOpacity(0.3),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: QrImageView(
              data: _pairingPayload,
              version: QrVersions.auto,
              size: 200.0,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            widget.myProfile.callsign,
            style: const TextStyle(
              color: Colors.cyanAccent,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          Text(
            'Token ID: ${_currentTokenId.substring(0, 16)}...',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: C2Colors.emeraldAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('COPY PAIRING CODE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                onPressed: _copyPairingCode,
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.cyanAccent,
                  side: const BorderSide(color: Colors.cyanAccent),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('REGENERATE TOKEN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                onPressed: _regenerateToken,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScanTab() {
    return Column(
      children: [
        // Camera Scanner Preview Box
        Container(
          height: 240,
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.cyanAccent, width: 2),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: MobileScanner(
              onDetect: (capture) {
                final List<Barcode> barcodes = capture.barcodes;
                for (final barcode in barcodes) {
                  if (barcode.rawValue != null) {
                    _parseAndAddContact(barcode.rawValue!);
                    break;
                  }
                }
              },
            ),
          ),
        ),

        // Text Paste Input Bar
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'OR PASTE PAIRING CODE BELOW:',
                style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pairingInputController,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      decoration: InputDecoration(
                        hintText: 'Paste c2://pair?data=...',
                        hintStyle: const TextStyle(color: Colors.white38, fontSize: 11),
                        filled: true,
                        fillColor: const Color(0xFF1E293B),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                    onPressed: () => _parseAndAddContact(_pairingInputController.text),
                    child: const Text('PAIR', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
