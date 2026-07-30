import 'dart:convert';
import 'dart:io' show InternetAddress, InternetAddressType, SecurityContext;

/// Where a seed node sits relative to the operator's own network.
///
/// Classified syntactically from the URL host — deliberately without a DNS
/// lookup, so the decision cannot be changed by whoever answers the query.
enum NodeLocality {
  /// Traffic never leaves the device: loopback literals and `localhost`.
  loopback,

  /// Reachable only from the local network: RFC1918, CGNAT, link-local and
  /// IPv6 ULA literals, plus the private-use name suffixes and bare
  /// single-label hostnames.
  privateNetwork,

  /// A routable name or address, or a dotted name we cannot place. Anything
  /// on the path between here and there can read plaintext metadata.
  publicNetwork,
}

/// How much the client is willing to trust an unencrypted transport **to a
/// relay node**.
///
/// Scoped to the relay path on purpose. Device-to-device links are governed
/// separately by [P2PLinkPolicy] — see the note there for why the two decisions
/// are not the same decision.
enum TransportPolicy {
  /// Plaintext only where it cannot leave the local network. TLS is required
  /// for anything routable. This is the default.
  ///
  /// A dotted name that is not a known private suffix counts as public even if
  /// it happens to resolve to a LAN address — split-horizon DNS is the reason
  /// [allowAllPlaintext] exists.
  privateNetworkPlaintext,

  /// TLS everywhere, including on the LAN. Every node must present a
  /// certificate or it is skipped.
  tlsOnly,

  /// Plaintext to anything. For a lab, or for a private deployment behind
  /// split-horizon DNS where the syntactic check gets the wrong answer.
  allowAllPlaintext,
}

/// Whether device-to-device links may run in the clear.
///
/// Deliberately a separate decision from [TransportPolicy], and separately
/// configured, because the two paths are not comparable:
///
/// - A relay link can be upgraded. A node has an address an operator controls,
///   so it can be issued a certificate — publicly trusted, or from an internal
///   CA pinned with `RELAY_CA_PEM_BASE64`. Refusing plaintext there means "use
///   the certificate you can obtain".
/// - A direct link cannot. There is no certificate infrastructure for handsets:
///   no name, no issuer, no way to pin one peer's leaf into another's build.
///   Refusing plaintext there does not upgrade the link, it removes it — and
///   with it the only transport that works when no relay is reachable, which is
///   the deployment this app exists for.
///
/// What the plaintext link exposes is stated in SECURITY.md: routing metadata
/// to an observer already on the local subnet. Bodies are sealed end-to-end
/// before they reach the link, and the link itself is authenticated in both
/// directions by Ed25519 challenge/response against paired contacts.
///
/// So folding this into `TRANSPORT_POLICY=tls-only` would have made "require a
/// certificate for the relay" silently mean "switch the mesh off". An operator
/// who wants that gets to ask for it.
enum P2PLinkPolicy {
  /// Direct links are dialled and accepted over plaintext WebSocket. Default,
  /// and unaffected by [TransportPolicy].
  plaintextAllowed,

  /// No plaintext direct link is dialled, and none is accepted. Since there is
  /// no encrypted alternative, this disables the P2P mesh outright: the device
  /// reaches other operators through a relay or not at all.
  plaintextDenied,
}

/// Maps the `P2P_PLAINTEXT` build define onto a policy.
///
/// Returns null when the value was not understood, so the caller can say so in
/// the event log rather than a typo deciding this quietly. Callers apply
/// [P2PLinkPolicy.plaintextAllowed] as the fallback: the permissive end here,
/// unlike [TransportPolicy], because the strict end is not a stricter version
/// of the same link, it is no link.
P2PLinkPolicy? parseP2PLinkPolicy(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'allow':
    case '':
      return P2PLinkPolicy.plaintextAllowed;
    case 'deny':
    case 'disable':
      return P2PLinkPolicy.plaintextDenied;
    default:
      return null;
  }
}

/// Why a direct link was not formed, for the operator's event log.
///
/// Written wherever a P2P dial is skipped, because the alternative — a mesh
/// that simply never finds anyone — is indistinguishable from being out of
/// range of every other device.
const String p2pPlaintextRefusalReason =
    'device-to-device links are plaintext and this build sets '
    'P2P_PLAINTEXT=deny, so the P2P mesh is disabled. Traffic routes through a '
    'relay node only.';

/// Name suffixes reserved for private use, so a plaintext hop cannot leave the
/// operator's own network. `.local` is mDNS; `.home.arpa` is RFC 8375; the rest
/// are conventional and explicitly not delegated in the public DNS root.
const _privateNameSuffixes = <String>[
  '.local',
  '.lan',
  '.internal',
  '.intranet',
  '.private',
  '.home.arpa',
];

/// Classifies [host] — a URL host component, without port or brackets.
NodeLocality classifyHost(String host) {
  final normalized = host.toLowerCase().trim();
  if (normalized.isEmpty) return NodeLocality.publicNetwork;

  // Uri.host strips the brackets from an IPv6 literal, but be tolerant of
  // callers that pass the authority through verbatim.
  final bare = normalized.startsWith('[') && normalized.endsWith(']')
      ? normalized.substring(1, normalized.length - 1)
      : normalized;

  final address = InternetAddress.tryParse(bare);
  if (address != null) return _classifyAddress(address);

  if (bare == 'localhost' || bare.endsWith('.localhost')) {
    return NodeLocality.loopback;
  }

  // A single-label name cannot be a public FQDN, so it is someone's LAN host.
  if (!bare.contains('.')) return NodeLocality.privateNetwork;

  for (final suffix in _privateNameSuffixes) {
    if (bare.endsWith(suffix)) return NodeLocality.privateNetwork;
  }

  return NodeLocality.publicNetwork;
}

NodeLocality _classifyAddress(InternetAddress address) {
  final b = address.rawAddress;

  if (address.type == InternetAddressType.IPv4) return _classifyIPv4(b);

  // IPv4-mapped (::ffff:a.b.c.d) carries a v4 address and must be judged as
  // one, or ::ffff:127.0.0.1 would read as public.
  if (b.length == 16) {
    final mappedPrefix = b.take(10).every((byte) => byte == 0) && b[10] == 0xff && b[11] == 0xff;
    if (mappedPrefix) return _classifyIPv4(b.sublist(12));

    // ::1
    if (b.take(15).every((byte) => byte == 0) && b[15] == 1) {
      return NodeLocality.loopback;
    }
    // fc00::/7 unique local, fe80::/10 link-local.
    if ((b[0] & 0xfe) == 0xfc) return NodeLocality.privateNetwork;
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return NodeLocality.privateNetwork;
  }

  return NodeLocality.publicNetwork;
}

NodeLocality _classifyIPv4(List<int> b) {
  if (b.length != 4) return NodeLocality.publicNetwork;

  if (b[0] == 127) return NodeLocality.loopback;
  if (b[0] == 10) return NodeLocality.privateNetwork;
  if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return NodeLocality.privateNetwork;
  if (b[0] == 192 && b[1] == 168) return NodeLocality.privateNetwork;
  if (b[0] == 169 && b[1] == 254) return NodeLocality.privateNetwork;
  // 100.64/10 is carrier-grade NAT, which is also what Tailscale hands out.
  if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return NodeLocality.privateNetwork;

  return NodeLocality.publicNetwork;
}

/// Whether [policy] permits connecting to a relay node at [url].
///
/// Relay seeds only. Direct peer links do not pass through here — they have no
/// URL an operator configured and no certificate they could present; see
/// [P2PLinkPolicy].
///
/// `https` is always allowed. Plaintext depends on where the node sits: the
/// default refuses it for anything routable, because envelope bodies staying
/// encrypted does not stop an observer on the path from logging who talks to
/// whom, when, and how much.
bool isTransportAllowed(String url, TransportPolicy policy) {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return false;
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https' || scheme == 'wss') return true;
  if (scheme != 'http' && scheme != 'ws') return false;

  switch (policy) {
    case TransportPolicy.tlsOnly:
      return false;
    case TransportPolicy.allowAllPlaintext:
      return true;
    case TransportPolicy.privateNetworkPlaintext:
      return classifyHost(uri.host) != NodeLocality.publicNetwork;
  }
}

/// Raised when the configured relay CA cannot be parsed. Fatal at startup by
/// the same reasoning as [SecureStorageUnavailable]: silently continuing with
/// platform roots only would mean the node the operator meant to pin to now
/// reads as unreachable, with nothing saying why.
class RelayTrustAnchorInvalid implements Exception {
  final String detail;
  const RelayTrustAnchorInvalid(this.detail);
  @override
  String toString() => 'RelayTrustAnchorInvalid: $detail';
}

/// Builds a trust context that accepts certificates issued by [caPemBase64],
/// in addition to the platform root store.
///
/// An isolated deployment cannot obtain a publicly-trusted certificate — there
/// is no ACME challenge to answer on a network with no route to the internet —
/// so without a way to pin an internal CA, "serve wss://" is not actually
/// reachable for the deployment this app is built for. The client's HTTP stack
/// is `dart:io`, which consults neither iOS ATS/Keychain profiles nor Android's
/// network security config, so installing the CA on the device does not work
/// either: it has to be handed to the process.
///
/// Returns null when [caPemBase64] is empty, meaning "platform roots only".
SecurityContext? relayTrustContext(String caPemBase64) {
  final trimmed = caPemBase64.trim();
  if (trimmed.isEmpty) return null;

  final List<int> pem;
  try {
    pem = base64Decode(trimmed);
  } catch (_) {
    throw const RelayTrustAnchorInvalid(
        'RELAY_CA_PEM_BASE64 is not valid base64');
  }

  // withTrustedRoots keeps the platform roots, so pinning an internal CA does
  // not break a second seed node that uses a public certificate.
  final context = SecurityContext(withTrustedRoots: true);
  try {
    context.setTrustedCertificatesBytes(pem);
  } catch (e) {
    throw RelayTrustAnchorInvalid('CA certificate rejected: $e');
  }
  return context;
}

/// One-line reason a URL was skipped, for the operator's event log.
String transportRefusalReason(String url, TransportPolicy policy) {
  final uri = Uri.tryParse(url);
  final scheme = uri?.scheme.toLowerCase() ?? '';

  if (scheme != 'http' && scheme != 'ws') {
    return 'unsupported scheme "$scheme"';
  }
  if (policy == TransportPolicy.tlsOnly) {
    return 'plaintext transport is disabled (TLS-only)';
  }
  return 'plaintext to a routable host exposes routing metadata; '
      'serve wss:// or use a private-network address';
}
