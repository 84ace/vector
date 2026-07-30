import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Raised when a ciphertext cannot be decrypted under any key this session can
/// legitimately derive. Always treat as hostile input.
class RatchetFailure implements Exception {
  final String reason;
  const RatchetFailure(this.reason);
  @override
  String toString() => 'RatchetFailure: $reason';
}

/// Per-message ratchet header. Travels with the ciphertext and is bound into the
/// AEAD's additional data, so none of it can be altered in flight.
class RatchetHeader {
  /// Base64 X25519 public key of the sender's current ratchet keypair.
  final String dh;

  /// Number of messages in the sender's previous sending chain, so a receiver
  /// that missed the tail of it knows how many keys to derive and retain.
  final int pn;

  /// Index of this message within the sender's current sending chain.
  final int n;

  const RatchetHeader({required this.dh, required this.pn, required this.n});

  Map<String, dynamic> toJson() => {'dh': dh, 'pn': pn, 'n': n};

  static RatchetHeader fromJson(Map<String, dynamic> json) {
    final dh = json['dh'];
    final pn = json['pn'];
    final n = json['n'];
    if (dh is! String || dh.isEmpty || pn is! int || n is! int || pn < 0 || n < 0) {
      throw const RatchetFailure('malformed ratchet header');
    }
    return RatchetHeader(dh: dh, pn: pn, n: n);
  }

  /// Canonical bytes bound into the AEAD as additional data, alongside the
  /// envelope header the caller supplies.
  List<int> get canonical => utf8.encode('$dh|$pn|$n');
}

/// One message key, with the header it belongs to.
class RatchetMessageKey {
  final SecretKey key;
  final RatchetHeader header;
  const RatchetMessageKey(this.key, this.header);
}

/// A Double Ratchet session with one contact.
///
/// This is the real construction — an alternating Diffie-Hellman ratchet over
/// per-message symmetric chains — not a static key with extra steps:
///
///   * **Forward secrecy.** A chain key advances by a one-way HMAC step and the
///     previous value is discarded, and each message key is deleted the moment
///     it is used. Compromising the device today does not decrypt traffic
///     captured yesterday.
///   * **Post-compromise recovery.** Every time a party receives a new ratchet
///     public key it performs a DH step with a freshly generated keypair and
///     mixes the result into the root key. An adversary who stole session state
///     loses it again after one round trip in which it did not interfere.
///
/// **Why the roles are assigned by key order.** A textbook Double Ratchet is
/// asymmetric: the responder has no sending chain until it receives the
/// initiator's first message. Signal gets away with that because whoever sends
/// first *is* the initiator, and it resolves simultaneous initiation by keeping
/// several sessions per contact and trying each on decrypt.
///
/// Neither applies here. Both operators already hold each other's static X25519
/// key from pairing, so both can derive the same root secret offline with no
/// extra round trip — and either operator must be able to message first. So the
/// operator whose agreement key sorts lower is the initiator, deterministically
/// and without negotiation, and the responder is given a *bootstrap* sending
/// chain derived straight from the root secret rather than from a DH step. Both
/// sides can therefore send immediately, and both can decrypt what the other
/// sends first.
///
/// That bootstrap is also what removes the crossing problem. A new ratchet
/// keypair is only ever generated while *receiving* a new one (as in the
/// specification), and the responder's first messages carry its static key —
/// which the initiator already holds as its remote ratchet key, so they trigger
/// no DH step. The root key therefore only ever advances on a receive, which
/// cannot happen on both sides from the same root. Strict alternation follows,
/// and two peers cannot diverge by sending at the same moment.
class DoubleRatchetSession {
  static const _rootInfo = 'vector-c2/ratchet/v3/root';
  static const _bootstrapInfo = 'vector-c2/ratchet/v3/bootstrap-chain';
  static const _kdfInfo = 'vector-c2/ratchet/v3/kdf';

  /// Domain separators for the symmetric chain step. Distinct constants under
  /// the same HMAC key give two independent outputs; reusing one would make the
  /// message key equal to the next chain key.
  static const _messageKeyConstant = 0x01;
  static const _chainKeyConstant = 0x02;

  /// Cap on how far ahead of the expected index a single chain may jump. A
  /// header claiming a huge `n` would otherwise make us derive that many keys.
  static const maxSkipPerChain = 256;

  /// Cap on retained out-of-order keys across all chains. Call signalling
  /// delivers ICE candidates in bursts that genuinely arrive out of order, so
  /// this cannot be zero — but it must not grow without bound either.
  static const maxStoredSkippedKeys = 1024;

  static final _x25519 = X25519();
  static final _hmac = Hmac.sha256();

  /// True when this device is the initiator for this pair.
  final bool isInitiator;

  SimpleKeyPair _dhSelf;
  String _dhSelfPublic;
  String? _dhRemote;

  Uint8List _rootKey;
  Uint8List? _chainSend;
  Uint8List? _chainRecv;

  int _sendCount = 0;
  int _recvCount = 0;
  int _previousSendCount = 0;

  /// Out-of-order message keys, keyed by `"<ratchet pub>|<n>"`.
  final Map<String, Uint8List> _skipped;

  DoubleRatchetSession._({
    required this.isInitiator,
    required SimpleKeyPair dhSelf,
    required String dhSelfPublic,
    required String? dhRemote,
    required Uint8List rootKey,
    required Uint8List? chainSend,
    required Uint8List? chainRecv,
    required int sendCount,
    required int recvCount,
    required int previousSendCount,
    required Map<String, Uint8List> skipped,
  })  : _dhSelf = dhSelf,
        _dhSelfPublic = dhSelfPublic,
        _dhRemote = dhRemote,
        _rootKey = rootKey,
        _chainSend = chainSend,
        _chainRecv = chainRecv,
        _sendCount = sendCount,
        _recvCount = recvCount,
        _previousSendCount = previousSendCount,
        _skipped = skipped;

  /// Establishes a session from the two long-term X25519 identities.
  ///
  /// Both sides compute the identical root secret from the static-static
  /// agreement, so there is no handshake and no extra round trip. Roles follow
  /// from the key ordering, which both sides can evaluate independently.
  static Future<DoubleRatchetSession> establish({
    required SimpleKeyPair selfAgreementKeyPair,
    required String selfKexPublicKey,
    required String remoteKexPublicKey,
  }) async {
    if (selfKexPublicKey == remoteKexPublicKey) {
      throw const RatchetFailure('cannot establish a session with self');
    }

    final shared = await _x25519.sharedSecretKey(
      keyPair: selfAgreementKeyPair,
      remotePublicKey: _publicKey(remoteKexPublicKey),
    );

    final salt = ([selfKexPublicKey, remoteKexPublicKey]..sort()).join('|');
    final root = Uint8List.fromList(await _hkdf(
      secret: await shared.extractBytes(),
      salt: utf8.encode(salt),
      info: _rootInfo,
      length: 32,
    ));

    // The bootstrap chain is derived from the root by both sides, so the
    // responder can send before it has ever received anything.
    final bootstrap = Uint8List.fromList(await _hkdf(
      secret: root,
      salt: const <int>[],
      info: _bootstrapInfo,
      length: 32,
    ));

    final initiator = selfKexPublicKey.compareTo(remoteKexPublicKey) < 0;

    if (initiator) {
      // Fresh ratchet keypair and one DH step, giving a sending chain that the
      // responder derives on receipt.
      final ephemeral = await _x25519.newKeyPair();
      final ephemeralPublic = base64Encode((await ephemeral.extractPublicKey()).bytes);
      final stepped = await _advanceRoot(
        rootKey: root,
        dhOutput: await _diffieHellman(ephemeral, remoteKexPublicKey),
      );

      return DoubleRatchetSession._(
        isInitiator: true,
        dhSelf: ephemeral,
        dhSelfPublic: ephemeralPublic,
        dhRemote: remoteKexPublicKey,
        rootKey: stepped.rootKey,
        chainSend: stepped.chainKey,
        // The responder's first messages ride the bootstrap chain.
        chainRecv: bootstrap,
        sendCount: 0,
        recvCount: 0,
        previousSendCount: 0,
        skipped: {},
      );
    }

    // Responder: the static agreement keypair doubles as the initial ratchet
    // keypair, which is why the initiator's remote ratchet key starts out equal
    // to it and its bootstrap messages trigger no DH step.
    return DoubleRatchetSession._(
      isInitiator: false,
      dhSelf: selfAgreementKeyPair,
      dhSelfPublic: selfKexPublicKey,
      dhRemote: remoteKexPublicKey,
      rootKey: root,
      chainSend: bootstrap,
      chainRecv: null,
      sendCount: 0,
      recvCount: 0,
      previousSendCount: 0,
      skipped: {},
    );
  }

  /// Derives the next sending message key and advances the sending chain.
  Future<RatchetMessageKey> nextSendingKey() async {
    final chain = _chainSend;
    if (chain == null) {
      throw const RatchetFailure('no sending chain established');
    }

    final derived = await _stepChain(chain);
    _chainSend = derived.nextChainKey;

    final header = RatchetHeader(
      dh: _dhSelfPublic,
      pn: _previousSendCount,
      n: _sendCount,
    );
    _sendCount++;

    return RatchetMessageKey(SecretKey(derived.messageKey), header);
  }

  /// Resolves the message key for an inbound [header], performing a DH ratchet
  /// step and skipping over gaps as required.
  ///
  /// The returned key is consumed: a second call with the same header fails,
  /// which is what rejects a replayed ciphertext.
  Future<SecretKey> receivingKey(RatchetHeader header) async {
    final stored = _skipped.remove('${header.dh}|${header.n}');
    if (stored != null) return SecretKey(stored);

    if (header.dh != _dhRemote) {
      // A new ratchet key from the peer. Retain the tail of the chain we were
      // on, then step the root twice: once for the new receiving chain, once
      // for a new sending chain under a freshly generated keypair.
      await _skipChainKeys(header.pn, _dhRemote);
      await _dhRatchet(header.dh);
    }

    await _skipChainKeys(header.n, _dhRemote);

    final chain = _chainRecv;
    if (chain == null) {
      throw const RatchetFailure('no receiving chain for this ratchet key');
    }
    if (header.n < _recvCount) {
      // Older than the chain position and not in the skipped set, so its key
      // has already been used and deleted.
      throw const RatchetFailure('message key already used (replay or duplicate)');
    }

    final derived = await _stepChain(chain);
    _chainRecv = derived.nextChainKey;
    _recvCount++;
    return SecretKey(derived.messageKey);
  }

  /// Derives and retains keys for messages between the current position and
  /// [until], so a later delivery can still be opened.
  Future<void> _skipChainKeys(int until, String? chainOwner) async {
    final chain = _chainRecv;
    if (chain == null || chainOwner == null) return;

    if (until - _recvCount > maxSkipPerChain) {
      throw const RatchetFailure('chain gap exceeds the permitted skip window');
    }

    var current = chain;
    while (_recvCount < until) {
      final derived = await _stepChain(current);
      _skipped['$chainOwner|$_recvCount'] = derived.messageKey;
      current = derived.nextChainKey;
      _recvCount++;
    }
    _chainRecv = current;

    // Bounded, oldest-first. Insertion order is chain order, so the entries
    // dropped are the ones least likely to still be in flight.
    while (_skipped.length > maxStoredSkippedKeys) {
      _skipped.remove(_skipped.keys.first);
    }
  }

  Future<void> _dhRatchet(String remoteRatchetKey) async {
    _previousSendCount = _sendCount;
    _sendCount = 0;
    _recvCount = 0;
    _dhRemote = remoteRatchetKey;

    final receiving = await _advanceRoot(
      rootKey: _rootKey,
      dhOutput: await _diffieHellman(_dhSelf, remoteRatchetKey),
    );
    _rootKey = receiving.rootKey;
    _chainRecv = receiving.chainKey;

    // A fresh keypair here is what gives post-compromise recovery: from this
    // point the root depends on a private key the adversary never saw.
    final ephemeral = await _x25519.newKeyPair();
    _dhSelf = ephemeral;
    _dhSelfPublic = base64Encode((await ephemeral.extractPublicKey()).bytes);

    final sending = await _advanceRoot(
      rootKey: _rootKey,
      dhOutput: await _diffieHellman(ephemeral, remoteRatchetKey),
    );
    _rootKey = sending.rootKey;
    _chainSend = sending.chainKey;
  }

  static Future<({Uint8List rootKey, Uint8List chainKey})> _advanceRoot({
    required Uint8List rootKey,
    required List<int> dhOutput,
  }) async {
    // HKDF with the current root as salt: the standard root-chain step.
    final out = await _hkdf(
      secret: dhOutput,
      salt: rootKey,
      info: _kdfInfo,
      length: 64,
    );
    return (
      rootKey: Uint8List.fromList(out.sublist(0, 32)),
      chainKey: Uint8List.fromList(out.sublist(32, 64)),
    );
  }

  static Future<({Uint8List messageKey, Uint8List nextChainKey})> _stepChain(
    Uint8List chainKey,
  ) async {
    final mk = await _hmac.calculateMac(
      const [_messageKeyConstant],
      secretKey: SecretKey(chainKey),
    );
    final ck = await _hmac.calculateMac(
      const [_chainKeyConstant],
      secretKey: SecretKey(chainKey),
    );
    return (
      messageKey: Uint8List.fromList(mk.bytes),
      nextChainKey: Uint8List.fromList(ck.bytes),
    );
  }

  static Future<List<int>> _diffieHellman(
    SimpleKeyPair keyPair,
    String remotePublicKey,
  ) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: _publicKey(remotePublicKey),
    );
    return shared.extractBytes();
  }

  static SimplePublicKey _publicKey(String base64Key) {
    final Uint8List bytes;
    try {
      bytes = base64Decode(base64Key);
    } catch (_) {
      throw const RatchetFailure('ratchet key is not valid base64');
    }
    if (bytes.length != 32) {
      throw const RatchetFailure('ratchet key is not a 32-byte X25519 key');
    }
    return SimplePublicKey(bytes, type: KeyPairType.x25519);
  }

  static Future<List<int>> _hkdf({
    required List<int> secret,
    required List<int> salt,
    required String info,
    required int length,
  }) async {
    final hkdf = Hkdf(hmac: _hmac, outputLength: length);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(secret),
      nonce: Uint8List.fromList(salt),
      info: utf8.encode(info),
    );
    return key.extractBytes();
  }

  // ---- Serialization -------------------------------------------------------

  /// Snapshot for persistence. Contains live key material and must only ever be
  /// written to the platform keystore.
  Future<Map<String, dynamic>> toJson() async => {
        'v': 3,
        'initiator': isInitiator,
        'dh_self_private': base64Encode(await _dhSelf.extractPrivateKeyBytes()),
        'dh_self_public': _dhSelfPublic,
        if (_dhRemote != null) 'dh_remote': _dhRemote,
        'root': base64Encode(_rootKey),
        if (_chainSend != null) 'ck_send': base64Encode(_chainSend!),
        if (_chainRecv != null) 'ck_recv': base64Encode(_chainRecv!),
        'ns': _sendCount,
        'nr': _recvCount,
        'pn': _previousSendCount,
        'skipped': {
          for (final entry in _skipped.entries) entry.key: base64Encode(entry.value),
        },
      };

  static Future<DoubleRatchetSession> fromJson(Map<String, dynamic> json) async {
    if (json['v'] != 3) {
      throw const RatchetFailure('unsupported ratchet state version');
    }
    try {
      final privateBytes = base64Decode(json['dh_self_private'] as String);
      final keyPair = await _x25519.newKeyPairFromSeed(privateBytes);

      final skippedRaw = (json['skipped'] as Map?) ?? const {};
      return DoubleRatchetSession._(
        isInitiator: json['initiator'] as bool,
        dhSelf: keyPair,
        dhSelfPublic: json['dh_self_public'] as String,
        dhRemote: json['dh_remote'] as String?,
        rootKey: Uint8List.fromList(base64Decode(json['root'] as String)),
        chainSend: json['ck_send'] == null
            ? null
            : Uint8List.fromList(base64Decode(json['ck_send'] as String)),
        chainRecv: json['ck_recv'] == null
            ? null
            : Uint8List.fromList(base64Decode(json['ck_recv'] as String)),
        sendCount: json['ns'] as int,
        recvCount: json['nr'] as int,
        previousSendCount: json['pn'] as int,
        skipped: {
          for (final entry in skippedRaw.entries)
            entry.key as String:
                Uint8List.fromList(base64Decode(entry.value as String)),
        },
      );
    } on RatchetFailure {
      rethrow;
    } catch (e) {
      throw RatchetFailure('corrupt ratchet state: $e');
    }
  }
}
