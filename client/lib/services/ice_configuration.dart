/// ICE server configuration for calls, resolved from build-time defines.
///
/// The standing decision is **no TURN by default**: a call that cannot find a
/// direct path fails visibly rather than silently relaying media through a third
/// party. That default is unchanged here. What this adds is a way to make the
/// other choice at deploy time instead of by patching source, and a description
/// of what each option exposes, so the trade is made deliberately.
class IceConfiguration {
  /// STUN servers, used to discover the device's public address so a direct
  /// path can be found. May be empty.
  final List<String> stunUrls;

  /// TURN servers, which relay media when no direct path exists. Empty by
  /// default — see [relaysMedia].
  final List<IceTurnServer> turnServers;

  const IceConfiguration({required this.stunUrls, required this.turnServers});

  /// True when a third party may carry call media.
  ///
  /// A TURN relay sees both endpoints' addresses and the full media stream. The
  /// stream stays DTLS-SRTP encrypted end-to-end, so the relay cannot listen to
  /// the call — but it learns who called whom, for how long, and from where.
  bool get relaysMedia => turnServers.isNotEmpty;

  /// True when a public STUN server will learn this device's address.
  ///
  /// Worth surfacing: the defaults are Google's public STUN servers, so by
  /// default placing a call discloses the operator's IP to Google. On an
  /// isolated network they are simply unreachable and host candidates carry the
  /// call, at the cost of some gathering delay.
  bool get usesPublicStun => stunUrls.any((url) => url.contains('google.com'));

  /// The `iceServers` list flutter_webrtc expects.
  List<Map<String, dynamic>> toRtcIceServers() => [
        for (final url in stunUrls) {'urls': url},
        for (final turn in turnServers) turn.toRtcIceServer(),
      ];

  /// Resolves configuration from build-time defines.
  ///
  /// - `STUN_SERVERS`: comma-separated. Pass an empty string to disable STUN
  ///   entirely, which is the right choice on an isolated network where the
  ///   public servers are unreachable anyway.
  /// - `TURN_URLS`: comma-separated. Empty (the default) means no TURN.
  /// - `TURN_USERNAME` / `TURN_CREDENTIAL`: long-term credentials.
  static IceConfiguration fromDefines({
    required String stunServers,
    required String turnUrls,
    required String turnUsername,
    required String turnCredential,
  }) {
    final stun = _splitList(stunServers);
    final turns = _splitList(turnUrls);

    return IceConfiguration(
      stunUrls: stun,
      turnServers: [
        for (final url in turns)
          IceTurnServer(
            url: url,
            username: turnUsername,
            credential: turnCredential,
          ),
      ],
    );
  }

  /// Warnings an operator should see in the event log, or empty when the
  /// deployment makes no privacy trade beyond the default.
  List<String> get advisories => [
        if (relaysMedia)
          'TURN is configured. When no direct path exists, media is relayed via '
              '${turnServers.map((t) => t.url).join(', ')}. That relay sees both '
              'endpoints\' addresses and the encrypted stream — it cannot listen '
              'to the call, but it learns who called whom, when, and from where.',
        if (usesPublicStun)
          'Calls use public STUN (Google). Placing a call discloses this '
              'device\'s address to that server. Build with '
              '--dart-define=STUN_SERVERS= to disable, or point it at your own.',
      ];

  static List<String> _splitList(String raw) => raw
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

class IceTurnServer {
  final String url;
  final String username;
  final String credential;

  const IceTurnServer({
    required this.url,
    required this.username,
    required this.credential,
  });

  Map<String, dynamic> toRtcIceServer() => {
        'urls': url,
        'username': username,
        'credential': credential,
      };
}
