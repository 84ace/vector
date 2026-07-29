# Vector C2 — Security Model

This document states what the system protects, how, and — just as importantly —
what it does not protect. Read the limitations section before relying on this for
anything that matters.

## Identity

Each device generates two keypairs on first launch and stores the private halves
in the iOS Keychain / Android Keystore (via `flutter_secure_storage`), never in
`SharedPreferences`:

| Key | Algorithm | Purpose |
|---|---|---|
| Identity key | Ed25519 | Signs every envelope; answers connection challenges |
| Agreement key | X25519 | Derives pairwise session keys |

The operator ID is **derived from the identity key**:

```
operator_id = "op-" + hex(sha256(ed25519_public_key))[0:16]
```

This makes IDs self-certifying. Any party — a peer, the relay — can recompute the
ID from the key attached to a message and compare it against the claimed sender.
There is no directory to consult and no way to send under someone else's ID
without their private key.

Both the Dart client and the Go node implement this derivation. A golden vector
in `backend/pkg/relay/testdata/dart_interop.json` pins the two implementations
together; `TestDartClientInterop` fails if they ever drift.

## Envelope authentication

Every envelope carries `sender_sign_key` and a `signature` over:

```
canonical_header || 0x00 || sha256(encrypted_body)
```

where `canonical_header` is the version tag, message ID, type, sender ID, sender
key, recipient ID, group ID and timestamp. Receivers enforce, in order:

1. the signature verifies under the attached identity key;
2. `sender_id == derive(sender_sign_key)`;
3. the sender is a paired contact;
4. the body decrypts under a key derived from **our stored copy** of that
   contact's agreement key — never a key carried by the message.

Step 4 is the one that matters most. Anything failing these checks is discarded
before it can touch application state, and signature failures are written to the
operator's event log rather than dropped silently.

## Message encryption

**Pairwise (1:1 chat, call control, PTT to an individual, all control messages)**

X25519 static-static agreement → HKDF-SHA256 → AES-256-GCM, with a fresh random
96-bit nonce per message and the canonical header bound in as additional
authenticated data. Accepted nonces are remembered per peer within a bounded
window, so a captured ciphertext cannot be replayed.

**Team (telemetry, group chat, broadcasts, SOS)**

A 256-bit random team key, generated on-device and exchanged with each contact
inside the pairwise-encrypted `PAIR_ACK`. Epoch keys are HKDF-derived from it.
Removing a contact rotates the key and distributes the new one pairwise to the
members who remain.

## Live calls (WebRTC)

Voice and video calls run over WebRTC. Media is DTLS-SRTP between the two
devices and does not pass through the relay at all.

The DTLS fingerprint lives in the SDP, and the SDP — along with every ICE
candidate — travels inside a sealed, signed envelope on the pairwise channel.
So the fingerprint exchange is authenticated against an identity that has
already been proven: a relay that tampers with signalling breaks the envelope
signature, and one that forwards it faithfully still cannot decrypt the media.

Only public STUN servers are configured. There is **no TURN server**, which is a
deliberate trade: a call between two peers behind symmetric NAT will fail to
connect rather than silently relaying media through a third party. If calls need
to work across arbitrary carrier networks, add TURN in
`WebRtcCallService._iceServers` — and note that a TURN relay sees the encrypted
media stream and both endpoints' addresses.

Push-to-talk clips still use the store-and-forward path, sealed the same way as
messages: they have to survive the recipient being offline, which WebRTC cannot do.

## Transport

Connections to a relay node run an Ed25519 challenge/response before the node
will route anything:

```
node   → { type: AUTH_CHALLENGE, nonce }
client → { type: AUTH_RESPONSE, operator_id, sign_key, signature(nonce) }
node   → { type: AUTH_RESULT, ok }
```

The node verifies the signature *and* that the claimed ID derives from the
presented key, then stamps `sender_id`/`sender_sign_key` on every envelope from
that session — a client cannot send under another name.

Direct device-to-device links run the same handshake in both directions, and
additionally refuse peers that are not already paired contacts.

Set `TLS_CERT_FILE` and `TLS_KEY_FILE` to serve `wss://`. The node logs a warning
at startup when it is not configured.

**The client refuses plaintext where it would matter.** Rather than a flag nobody
remembers to set, the decision follows the node's address: `https://` is accepted
anywhere, and plaintext only to loopback or a private-network address. A routable
plaintext node is skipped and the reason is written to the operator's event log —
silently dropping it made a misconfiguration look identical to an outage. Build
with `TRANSPORT_POLICY=tls-only` to require TLS on the LAN too.

Classification is syntactic, with no DNS lookup, so whoever answers the query
cannot influence it. A dotted name therefore counts as routable even if it
resolves to a LAN address; `TRANSPORT_POLICY=any` exists for split-horizon DNS.

An isolated network cannot obtain a publicly-trusted certificate, so an internal
CA can be pinned into the build with `RELAY_CA_PEM_BASE64`, alongside — not
instead of — the platform roots. It has to be pinned into the process: the
client's `dart:io` transport consults neither an iOS profile nor Android's user
certificate store. A CA that will not parse is fatal at startup, by the same
reasoning as a missing keystore. See `DEPLOYMENT.md`.

## Pairing

1. Operator A scans B's QR code. This is the out-of-band step: it carries B's
   identity and agreement keys over a channel A controls.
2. A stores B as a contact and sends a signed `PAIR_REQUEST`.
3. B is shown the request together with the **safety number** and must approve.
4. On approval B stores A, and sends a pairwise-encrypted `PAIR_ACK` carrying the
   team key.

`PAIR_REQUEST` is the only message type whose body is signed but not encrypted —
it is the bootstrap, addressed to a peer that has no contact record for the
sender yet and therefore cannot derive a session key. It carries only public
material, and its signature still binds it to an unforgeable operator ID.

An unsolicited `PAIR_ACK` is refused: the receiver must have an outstanding
request for that operator. Pairing tokens are 128 random bits.

**Safety numbers.** 60 decimal digits over SHA-256 of both identity keys, shown
in the approval dialog and per-contact in Settings. Read them aloud with the
other operator; if they differ, the pairing is being intercepted.

## What this does not protect against

Stated plainly, because the previous version of this code claimed protections it
did not have:

- **No forward secrecy.** Pairwise keys are static per contact. Compromising a
  device exposes previously captured traffic for its conversations. This is not a
  Double Ratchet, and nothing here should be described as Signal or X3DH.
- **Team key is shared.** Every paired member can read all team traffic. A
  removed member who kept an old epoch key can still read messages from that
  epoch — rotation only protects what comes after.
- **Rotation is best-effort.** Members who are offline during a rekey do not get
  the new key until they reconnect; the event log records when distribution was
  incomplete.
- **Metadata is visible to the relay.** It cannot read bodies, but it sees who
  talks to whom, when, and how much. TLS hides this from the network path, not
  from the node operator.
- **Local network presence.** P2P discovery broadcasts the device's identity key
  to the subnet every 10 seconds. It can be disabled, and the app falls back to
  the relay.
- **No node-to-node authentication.** `/announce` accepts peer records from
  private addresses only. Federation across untrusted networks would need node
  identity keys, which is not implemented.
- **Compromised endpoint.** Nothing here defends against a device an adversary
  controls.

## Breaking change from the pre-v2 build

Operator IDs and key formats changed, so **all contacts must re-pair.** Contacts
saved by an older build carry no verifiable keys and are dropped on first launch,
with an entry written to the event log explaining why. This is deliberate: the
old keys offered no security, and keeping them would have shown unverifiable
operators as trusted.

## Running the tests

```bash
cd backend && go test -race ./...
```

```bash
cd client && flutter test
```

The end-to-end suite needs a running node:

```bash
cd backend && PORT=18080 go run ./cmd/node
```

```bash
cd client && RELAY_URL=http://127.0.0.1:18080 flutter test test/live_relay_test.dart
```
