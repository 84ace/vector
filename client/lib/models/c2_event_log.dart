enum EventSeverity { info, warning, alert, security }

class C2EventLog {
  final String id;
  final String title;
  final String details;
  final EventSeverity severity;
  final DateTime timestamp;

  C2EventLog({
    required this.id,
    required this.title,
    required this.details,
    required this.severity,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'details': details,
        'severity': severity.name,
        'timestamp': timestamp.millisecondsSinceEpoch,
      };

  factory C2EventLog.fromJson(Map<String, dynamic> json) {
    return C2EventLog(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      details: json['details'] ?? '',
      severity: _parseSeverity(json['severity']),
      timestamp: json['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['timestamp'])
          : DateTime.now(),
    );
  }

  static EventSeverity _parseSeverity(String? str) {
    switch (str) {
      case 'warning':
        return EventSeverity.warning;
      case 'alert':
        return EventSeverity.alert;
      case 'security':
        return EventSeverity.security;
      default:
        return EventSeverity.info;
    }
  }
}
