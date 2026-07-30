# Vector C2 — outstanding work

Paste the section below as the opening prompt for a fresh session, or point an
agent at this file. Everything it needs is stated here; no prior conversation
is required.

---

## Context

Vector C2 is a tactical comms app: a Flutter client (`client/`) and a Go relay
node (`backend/`). Operators pair device-to-device, share position telemetry,
message, push-to-talk, and place voice/video calls. It works today — pairing,
telemetry, PTT, voice and video calls are all verified on real hardware (a Mac
and an Android handset on the same LAN).

Read `SECURITY.md` first. It states the threat model, what is protected and how,
and — deliberately — what is not. `DEPLOYMENT.md` covers getting a relay node
deployed with TLS and configuring the client to trust it.

**Architecture, briefly**

- Identity: Ed25519 (signing) + X25519 (key agreement) per device, in the
  platform keystore. Operator IDs are *derived from* the signing key
  (`op-<first 16 hex of sha256(pubkey)>`), so they are self-certifying and
  cannot be claimed by another device. Both Dart and Go implement this
  derivation; `backend/pkg/relay/testdata/dart_interop.json` pins them together.
- Every envelope is signed; recipients verify the signature *and* that the
  claimed sender ID derives from the attached key, then decrypt using their
  **stored** copy of that contact's key — never a key carried by the message.
- Pairwise: a Double Ratchet over the static X25519 identities — alternating DH
  ratchet, per-message symmetric chains, AES-256-GCM, envelope and ratchet
  headers both bound in as AAD. Team traffic: a shared symmetric key exchanged
  during pairing.
- Calls are WebRTC; media is DTLS-SRTP peer-to-peer and never touches the relay.
  Signalling rides the sealed channel, so the DTLS fingerprint exchange is
  authenticated.

**Decisions already made — please do not relitigate**

- Secure storage failure is fatal by design. Never fall back to
  `SharedPreferences` for key material; the app shows a blocking error instead.
  This now covers ratchet state as well as identity keys.
- No protocol is described as Signal, X3DH, or MLS. The team key is a shared
  symmetric key and says so. The pairwise path *is* a Double Ratchet and may say
  so, but the two places it differs from X3DH are written down in `SECURITY.md`
  and must stay written down.
- No TURN is configured by default: a call that cannot find a direct path fails
  visibly rather than silently relaying media through a third party. It is now a
  build-time opt-in (`TURN_URLS`) rather than a source edit, and enabling it logs
  what the relay learns. That decision is settled.
- Plaintext transport is refused to any routable host and permitted on the LAN,
  keyed on the node's address rather than on a flag. `TRANSPORT_POLICY=tls-only`
  tightens it; `any` is the documented escape hatch for split-horizon DNS.
- Unpaired peers may hold a P2P link but may send *only* a pairing request
  (`P2PMeshEngine._dispatchFrame`). Refusing them outright makes pairing
  impossible on an isolated network — that bug has already been fixed once.
- Delivery of a team key is confirmed by acknowledgement, not by a transport
  accepting the envelope. Do not "simplify" that back to clearing on send.

## Outstanding work

### 1. Prekeys, to close the forward-secrecy gap at conversation start

The pairwise path is ratcheted, but the bootstrap has no prekeys: both sides
derive the root secret from the two static keys, so the **first chain in each
direction** is recoverable from the long-term keys plus the ratchet public key in
the header. Traffic sent before a conversation's first reply is therefore still
exposed by a device compromise; everything after it is not.

This is what X3DH's one-time prekeys solve. The obstacle is that there is no
server to publish them to and pairing is a QR exchange, so they would have to
ride the pairing payload (a small batch) with a story for exhaustion.

The limit is asserted by `test/double_ratchet_test.dart`, in the test named
`KNOWN LIMIT: ...`. If this is implemented, that test flips and the
`SECURITY.md` bullet must change with it.

### 2. Team traffic has no forward secrecy

The Double Ratchet covers pairwise only. Telemetry, group chat, broadcasts and
SOS use the shared epoch key, so a device compromise exposes captured team
traffic for every epoch whose key it holds.

A sender-keys scheme (per-sender ratcheted chain, distributed pairwise) is the
usual answer and the pairwise channel to distribute it already exists and is now
ratcheted. Note that telemetry is high-rate — every 4s per operator — so measure
before adding per-message asymmetric work to that path.

### 3. mobile_scanner cannot run on an Apple Silicon iOS simulator

`flutter build ios` works for device, profile and simulator. But
`mobile_scanner` 6.0.11's podspec sets
`EXCLUDED_ARCHS[sdk=iphonesimulator*] = i386 armv7 arm64`, so MLKit and the
plugin are never built for the only architecture an iOS 26+ Apple Silicon
simulator offers. The build *succeeds* and Flutter prints the affected targets,
but the resulting binary will not install there.

Options: test QR pairing on a physical device, or upgrade to `mobile_scanner`
7.x, which drops MLKit for the Vision API. That is a major version bump touching
`client/lib/ui/onboarding/qr_pairing_view.dart` and needs device testing.

macOS additionally needs a one-time device registration in the Apple developer
account for provisioning; that is an account action, not a code change.

### 4. Smaller known gaps

- **A team member who never returns stays behind.** Rotation is now tracked per
  recipient, retried whenever a route appears, and cleared only on
  acknowledgement — but there is no guarantee about *when* an absent operator
  catches up, and no upper bound after which they are dropped.
- **The node reads its certificate once at startup.** Renewal has to restart or
  signal it; there is no hot reload.
- **No node-to-node authentication.** `/announce` accepts peer records from
  private addresses only. Federation across untrusted networks would need node
  identity keys, which is not implemented.
- **`pod install` needs a UTF-8 locale.** Under Ruby 4.x, CocoaPods 1.16 fails
  with `Unicode Normalization not appropriate for ASCII-8BIT` if `LANG` is unset.
  Export `LANG=en_US.UTF-8` in bare shells and CI.

## Verifying your work

```bash
cd backend && gofmt -l . && go vet ./... && go test -race ./...
```

```bash
cd client && flutter analyze && flutter test
```

Both must be clean: the analyzer reports no issues, and all tests pass.

End-to-end against a live node:

```bash
cd backend && PORT=18080 go run ./cmd/node
```

```bash
cd client && RELAY_URL=http://127.0.0.1:18080 flutter test test/live_relay_test.dart
```

Over TLS, which also exercises certificate pinning — see `DEPLOYMENT.md` for
generating the CA:

```bash
cd backend && ./scripts/make-internal-ca.sh ./certs 127.0.0.1 localhost
PORT=18443 TLS_CERT_FILE=./certs/node.crt TLS_KEY_FILE=./certs/node.key go run ./cmd/node
```

```bash
cd client && RELAY_URL=https://localhost:18443 RELAY_CA_FILE=../backend/certs/ca.crt \
  flutter test test/live_relay_test.dart
```

`client/test/pairing_integration_test.dart` stands up two complete stacks on
real sockets and drives a full pairing. Run it after any change to the crypto,
the envelope, or `P2PMeshEngine`.

## How to test — this matters

Every serious bug in this project so far passed unit testing and only appeared
between two devices: an admission rule that blocked the one message pairing
depends on; a pairing request sent before any transport existed; a key exchange
that ran in one direction only; voice clips filtered out of their own
conversation. Each was invisible to tests that exercised components in
isolation.

So:

- **A regression test must fail against the original defect.** Reintroduce the
  bug, watch the test go red, then restore the fix. A test that passes either
  way proves nothing. Several existing tests were verified this way and say so
  in their comments — including the three forward-secrecy and post-compromise
  tests in `test/double_ratchet_test.dart`, which were checked by restoring
  static-static sealing.
- Prefer integration tests that stand up both ends over mocks of either.
- Layout bugs are cheap to catch: pump the real widget at 320×568 and assert
  `tester.takeException()` is null. Two overflow bugs shipped before this was
  routine.
- **Do not trust this file over the code.** The previous version of it described
  the iOS build as broken; it had already been fixed by uncommitted changes in
  the working tree, and the description cost real time. Reproduce before fixing.

## Working in this codebase

- Comments explain *why*, especially where something looks odd — most of them
  record a specific failure. Keep that standard; do not narrate what the code
  already says.
- Edit with explicit string anchors, not computed line offsets. `main.dart` and
  the call view were corrupted several times by index arithmetic that assumed
  member ordering; the analyzer caught it each time, but it cost real effort.
  This applies to `project.pbxproj` too.
