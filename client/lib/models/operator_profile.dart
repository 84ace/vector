enum OperatorRole { operator, teamLead, hqCommand }

class OperatorProfile {
  final String id;
  final String callsign;
  final String name;
  final OperatorRole role;
  final String avatarBase64;

  /// Base64 Ed25519 identity key. [id] is derived from this, so the pair is what
  /// authenticates a contact.
  final String signPublicKey;

  /// Base64 X25519 key-agreement key, used to derive the pairwise session key.
  final String kexPublicKey;

  final DateTime lastSeen;
  final bool isOnline;

  OperatorProfile({
    required this.id,
    required this.callsign,
    required this.name,
    required this.role,
    required this.avatarBase64,
    required this.signPublicKey,
    required this.kexPublicKey,
    required this.lastSeen,
    this.isOnline = true,
  });

  /// A contact is only usable if it carries both keys. Contacts persisted by the
  /// pre-v2 build carry neither and must be re-paired; they are dropped on load
  /// rather than silently kept as unverifiable entries.
  bool get hasValidKeys => signPublicKey.isNotEmpty && kexPublicKey.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'callsign': callsign,
        'name': name,
        'role': role.index,
        'avatar_base64': avatarBase64,
        'sign_public_key': signPublicKey,
        'kex_public_key': kexPublicKey,
        'last_seen': lastSeen.toIso8601String(),
        'is_online': isOnline,
      };

  factory OperatorProfile.fromJson(Map<String, dynamic> json) {
    final roleIndex = json['role'] as int? ?? 0;
    return OperatorProfile(
      id: json['id'] as String? ?? '',
      callsign: json['callsign'] as String? ?? 'OPERATOR',
      name: json['name'] as String? ?? 'Unknown Operator',
      role: OperatorRole.values[roleIndex.clamp(0, OperatorRole.values.length - 1)],
      avatarBase64: json['avatar_base64'] as String? ?? '',
      signPublicKey: json['sign_public_key'] as String? ?? '',
      kexPublicKey: json['kex_public_key'] as String? ?? '',
      lastSeen: json['last_seen'] != null
          ? DateTime.tryParse(json['last_seen'] as String) ?? DateTime.now()
          : DateTime.now(),
      isOnline: json['is_online'] as bool? ?? true,
    );
  }

  OperatorProfile copyWith({
    String? id,
    String? callsign,
    String? name,
    OperatorRole? role,
    String? avatarBase64,
    String? signPublicKey,
    String? kexPublicKey,
    DateTime? lastSeen,
    bool? isOnline,
  }) {
    return OperatorProfile(
      id: id ?? this.id,
      callsign: callsign ?? this.callsign,
      name: name ?? this.name,
      role: role ?? this.role,
      avatarBase64: avatarBase64 ?? this.avatarBase64,
      signPublicKey: signPublicKey ?? this.signPublicKey,
      kexPublicKey: kexPublicKey ?? this.kexPublicKey,
      lastSeen: lastSeen ?? this.lastSeen,
      isOnline: isOnline ?? this.isOnline,
    );
  }
}
