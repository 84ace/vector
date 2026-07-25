enum OperatorRole { operator, teamLead, hqCommand }

class OperatorProfile {
  final String id;
  final String callsign;
  final String name;
  final OperatorRole role;
  final String avatarBase64;
  final String publicKey;
  final DateTime lastSeen;
  final bool isOnline;

  OperatorProfile({
    required this.id,
    required this.callsign,
    required this.name,
    required this.role,
    required this.avatarBase64,
    required this.publicKey,
    required this.lastSeen,
    this.isOnline = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'callsign': callsign,
        'name': name,
        'role': role.index,
        'avatar_base64': avatarBase64,
        'public_key': publicKey,
        'last_seen': lastSeen.toIso8601String(),
        'is_online': isOnline,
      };

  factory OperatorProfile.fromJson(Map<String, dynamic> json) {
    return OperatorProfile(
      id: json['id'] ?? '',
      callsign: json['callsign'] ?? 'OPERATOR',
      name: json['name'] ?? 'Unknown Operator',
      role: OperatorRole.values[json['role'] ?? 0],
      avatarBase64: json['avatar_base64'] ?? '',
      publicKey: json['public_key'] ?? '',
      lastSeen: json['last_seen'] != null
          ? DateTime.parse(json['last_seen'])
          : DateTime.now(),
      isOnline: json['is_online'] ?? true,
    );
  }

  OperatorProfile copyWith({
    String? callsign,
    String? name,
    OperatorRole? role,
    String? avatarBase64,
    String? publicKey,
    DateTime? lastSeen,
    bool? isOnline,
  }) {
    return OperatorProfile(
      id: id,
      callsign: callsign ?? this.callsign,
      name: name ?? this.name,
      role: role ?? this.role,
      avatarBase64: avatarBase64 ?? this.avatarBase64,
      publicKey: publicKey ?? this.publicKey,
      lastSeen: lastSeen ?? this.lastSeen,
      isOnline: isOnline ?? this.isOnline,
    );
  }
}
