import 'package:flutter/material.dart';
import '../../models/arcgis_layer.dart';
import 'tactical_map_view.dart';
import '../theme/c2_colors.dart';

class TacticalLayerPanel extends StatefulWidget {
  final MapTileTheme currentTheme;
  final Function(MapTileTheme) onThemeChanged;
  final List<ArcGISLayer> layers;
  final Function(ArcGISLayer) onAddLayer;
  final Function(ArcGISLayer) onToggleLayer;
  final Function(ArcGISLayer) onDeleteLayer;

  const TacticalLayerPanel({
    super.key,
    required this.currentTheme,
    required this.onThemeChanged,
    required this.layers,
    required this.onAddLayer,
    required this.onToggleLayer,
    required this.onDeleteLayer,
  });

  @override
  State<TacticalLayerPanel> createState() => _TacticalLayerPanelState();
}

class _TacticalLayerPanelState extends State<TacticalLayerPanel> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  final ArcGISServiceType _selectedType = ArcGISServiceType.mapServer;

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: C2Colors.slateBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.layers, color: Colors.cyanAccent, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'TACTICAL MAP & OPERATIONAL LAYERS',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(color: Colors.white12),

            // Section 1: Base Map Themes
            const Text(
              'BASE MAP CANVAS THEME',
              style: TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                _buildThemeCard(
                  theme: MapTileTheme.darkVector,
                  label: 'VECTOR',
                  icon: Icons.map,
                ),
                const SizedBox(width: 8),
                _buildThemeCard(
                  theme: MapTileTheme.satellite,
                  label: 'SATELLITE',
                  icon: Icons.satellite_alt,
                ),
                const SizedBox(width: 8),
                _buildThemeCard(
                  theme: MapTileTheme.topoTerrain,
                  label: 'TOPO',
                  icon: Icons.terrain,
                ),
              ],
            ),

            const Divider(color: Colors.white12, height: 28),

            // Section 2: ArcGIS Operational Overlays
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'ARCGIS REST OVERLAY LAYERS',
                  style: TextStyle(color: Colors.purpleAccent, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                ),
                Text(
                  '${widget.layers.length} CONNECTED',
                  style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (widget.layers.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: C2Colors.slateCard,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'No active ArcGIS server overlay layers connected. Add a local LAN or web ArcGIS URL endpoint below.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              )
            else
              ...widget.layers.map((layer) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: C2Colors.slateCard,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                      leading: Switch(
                        value: layer.isVisible,
                        activeThumbColor: Colors.purpleAccent,
                        onChanged: (_) {
                          setState(() {
                            layer.isVisible = !layer.isVisible;
                          });
                          widget.onToggleLayer(layer);
                        },
                      ),
                      title: Text(layer.name, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                      subtitle: Text(layer.url, style: const TextStyle(color: Colors.white38, fontSize: 10), overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                        onPressed: () => widget.onDeleteLayer(layer),
                      ),
                    ),
                  )),

            const SizedBox(height: 14),

            // Add Custom ArcGIS Endpoint
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: const InputDecoration(
                hintText: 'Layer Title (e.g. Tactical Grid Overlay)',
                hintStyle: TextStyle(color: Colors.white38),
                filled: true,
                fillColor: C2Colors.slateCard,
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),

            TextField(
              controller: _urlController,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: const InputDecoration(
                hintText: 'http://services.arcgisonline.com/.../tile/{z}/{y}/{x}',
                hintStyle: TextStyle(color: Colors.white38),
                filled: true,
                fillColor: C2Colors.slateCard,
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purpleAccent,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('ADD ARCGIS OVERLAY LAYER', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                onPressed: () {
                  if (_urlController.text.isNotEmpty && _nameController.text.isNotEmpty) {
                    final newLayer = ArcGISLayer(
                      id: 'layer-${DateTime.now().millisecondsSinceEpoch}',
                      name: _nameController.text,
                      type: _selectedType,
                      url: _urlController.text,
                    );
                    widget.onAddLayer(newLayer);
                    _urlController.clear();
                    _nameController.clear();
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThemeCard({
    required MapTileTheme theme,
    required String label,
    required IconData icon,
  }) {
    final isSelected = widget.currentTheme == theme;

    return Expanded(
      child: InkWell(
        onTap: () {
          widget.onThemeChanged(theme);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? Colors.cyan.withValues(alpha: 0.2) : C2Colors.slateCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? Colors.cyanAccent : Colors.white12,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(icon, color: isSelected ? Colors.cyanAccent : Colors.white54, size: 20),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.cyanAccent : Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
