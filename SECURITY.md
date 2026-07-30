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

A **Double Ratchet**: an alternating Diffie-Hellman ratchet over per-message
symmetric chains, then AES-256-GCM with a fresh random 96-bit nonce. Both the
canonical envelope header and the ratchet header are bound in as additional
authenticated data.

Every message gets its own key, derived by a one-way HMAC step and destroyed
immediately after use. Each time a party receives a new ratchet public key it
generates a fresh keypair, performs a DH step and mixes the result into the root
key. Replay needs no nonce list any more: a replayed ciphertext has no key left
to open it.

The session is established from the two static X25519 identities exchanged at
pairing, so there is no handshake and no extra round trip. The operator whose
agreement key sorts lower is the initiator — assigned by key order rather than by
who sends first, because a textbook responder has no sending chain until it has
received something, and either operator has to be able to message first. The
responder instead gets a bootstrap sending chain derived straight from the root
secret. That is also what keeps the two sides from diverging: a new ratchet
keypair is only ever generated while *receiving* one, so the root key advances on
one side at a time and two peers sending simultaneously cannot desynchronise.

A forged or corrupt ciphertext rolls the session back rather than advancing it,
so injecting one packet cannot break a conversation.

Ratchet state lives in the platform keystore alongside the identity keys — it
derives every future message key, so it gets the same protection. State that
cannot be read is discarded and the session re-established from the static keys,
costing at most the messages already in flight rather than the conversation.

Version 2 ciphertexts — static-static agreement, no forward secrecy — are still
accepted so a squad can update one device at a time, and receiving one writes a
warning to the operator's event log naming the contact. Nothing is ever sent as
version 2.

**Team (telemetry, group chat, broadcasts, SOS)**

A 256-bit random team key, generated on-device and exchanged with each contact
inside the pairwise-encrypted `PAIR_ACK`. Epoch keys are HKDF-derived from it.
Removing a contact rotates the key and distributes the new one pairwise to the
members who remain; each remaining member is tracked until it acknowledges the
new epoch, and delivery is retried whenever a route to it reappears.

## Live calls (WebRTC)

Voice and video calls run over WebRTC. Media is DTLS-SRTP between the two
devices and does not pass through the relay at all.

The DTLS fingerprint lives in the SDP, and the SDP — along with every ICE
candidate — travels inside a sealed, signed envelope on the pairwise channel.
So the fingerprint exchange is authenticated against an identity that has
already been proven: a relay that tampers with signalling breaks the envelope
signature, and one that forwards it faithfully still cannot decrypt the media.

**No TURN server is configured, and that is settled rather than pending.** A call
between two peers both behind symmetric NAT — typically on different carrier
networks — fails visibly rather than silently relaying media through a third
party. The failure surfaces as a `CALL FAILED` event, not as a call that rings
forever.

A deployment that needs calls across arbitrary carrier networks can opt in with
`--dart-define=TURN_URLS=…` (plus `TURN_USERNAME` and `TURN_CREDENTIAL`) instead
of patching source, so the choice is recorded where the deployment is described.
When TURN is enabled the app writes an advisory to the operator's event log
naming the relay, because a TURN server sees **both endpoints' addresses and the
full media stream**. The stream stays DTLS-SRTP encrypted end-to-end, so the
relay cannot listen to the call — but it learns who called whom, for how long,
and from where. STUN candidates are always offered ahead of relayed ones, so TURN
carries a call only when nothing direct works.

**Public STUN discloses the operator's address.** The defaults are Google's
public STUN servers, so by default placing a call tells Google this device's IP.
That, too, is written to the event log. Build with `--dart-define=STUN_SERVERS=`
to disable STUN entirely — correct on an isolated network, where the public
servers are unreachable anyway and host candidates carry the call — or point it
at a STUN server you run.

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

- **Forward secrecy has a gap at the start of each conversation.** Pairwise
  traffic is ratcheted, so seizing a device does not decrypt captured traffic in
  general. But the bootstrap has no prekeys — there is no server to publish them
  to and no spare round trip — so the *first* chain in each direction is a
  function of the two long-term keys plus a ratchet public key that travels in
  the message header. Traffic sent before a conversation's first reply is
  therefore still exposed by a device compromise. Everything from the first reply
  onwards is not. This is where X3DH's one-time prekeys would help, and they are
  not implemented; the limit is pinned by a test so it cannot change quietly.
- **Post-compromise recovery takes two round trips.** Stolen session state
  contains the ratchet keypair in use at that moment, so it can follow the next
  DH step. The adversary is locked out only once the compromised device has
  received a new ratchet key and generated a fresh keypair of its own, and traffic
  then depends on it — one message each way is not enough.
- **Team traffic is not ratcheted.** The Double Ratchet covers the pairwise path
  only. Team messages use the shared epoch key described above and have no
  forward secrecy.
- Nothing here is Signal or X3DH. It is a Double Ratchet over static X25519
  identities, with the bootstrap difference stated above.
- **Team key is shared.** Every paired member can read all team traffic. A
  removed member who kept an old epoch key can still read messages from that
  epoch — rotation only protects what comes after.
- **Rotation completes eventually, not immediately.** A member who is offline
  during a rekey does not hold the new key until they reconnect, and until then
  their team traffic will not decrypt. Delivery is now tracked per recipient and
  re-attempted whenever a route to them appears, and a recipient is only cleared
  once it acknowledges the epoch — a send accepted by a transport is not proof of
  receipt. Obligations are persisted, so a rotation outlives the process that
  performed it. What is still true: there is no guarantee about *when* an absent
  operator catches up, and one who never returns stays behind forever.
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
