enum ArcGISServiceType { mapServer, featureServer, tileServer, imageryServer }

class ArcGISLayer {
  final String id;
  final String name;
  final ArcGISServiceType type;
  final String url;
  bool isVisible;
  double opacity;

  ArcGISLayer({
    required this.id,
    required this.name,
    required this.type,
    required this.url,
    this.isVisible = true,
    this.opacity = 0.8,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'url': url,
        'is_visible': isVisible,
        'opacity': opacity,
      };

  factory ArcGISLayer.fromJson(Map<String, dynamic> json) {
    return ArcGISLayer(
      id: json['id'] ?? '',
      name: json['name'] ?? 'ArcGIS Layer',
      type: ArcGISServiceType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => ArcGISServiceType.mapServer,
      ),
      url: json['url'] ?? '',
      isVisible: json['is_visible'] ?? true,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 0.8,
    );
  }
}
