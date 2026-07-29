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
and — deliberately — what is not.

**Architecture, briefly**

- Identity: Ed25519 (signing) + X25519 (key agreement) per device, in the
  platform keystore. Operator IDs are *derived from* the signing key
  (`op-<first 16 hex of sha256(pubkey)>`), so they are self-certifying and
  cannot be claimed by another device. Both Dart and Go implement this
  derivation; `backend/pkg/relay/testdata/dart_interop.json` pins them together.
- Every envelope is signed; recipients verify the signature *and* that the
  claimed sender ID derives from the attached key, then decrypt using their
  **stored** copy of that contact's key — never a key carried by the message.
- Pairwise: X25519 → HKDF-SHA256 → AES-256-GCM, random nonce, envelope header
  bound in as AAD. Team traffic: a shared symmetric key exchanged during pairing.
- Calls are WebRTC; media is DTLS-SRTP peer-to-peer and never touches the relay.
  Signalling rides the sealed channel, so the DTLS fingerprint exchange is
  authenticated.

**Decisions already made — please do not relitigate**

- Secure storage failure is fatal by design. Never fall back to
  `SharedPreferences` for key material; the app shows a blocking error instead.
- No protocol is described as Signal, X3DH, or MLS. The team key is a shared
  symmetric key and says so. Keep the naming honest.
- No TURN was configured deliberately: a call that cannot find a direct path
  fails visibly rather than silently relaying media through a third party.
- Unpaired peers may hold a P2P link but may send *only* a pairing request
  (`P2PMeshEngine._dispatchFrame`). Refusing them outright makes pairing
  impossible on an isolated network — that bug has already been fixed once.

## Tasks, in rough order of consequence

### 1. TLS on the relay

Message bodies are end-to-end encrypted, but without TLS the routing metadata —
who talks to whom, when, how much — is exposed to anything on the network path.

The plumbing exists: `backend/cmd/node/main.go` reads `TLS_CERT_FILE` and
`TLS_KEY_FILE` (and `ALLOWED_ORIGINS` for browser clients), and logs a warning
at startup when unconfigured. The client negotiates `wss://` automatically when
a seed URL is `https://`, and `MeshClient(requireSecureTransport: true)` will
refuse plaintext nodes.

What is missing: a documented deployment path (certificate provisioning,
`docker-compose` wiring, and whether `requireSecureTransport` should default to
true once TLS is available).

### 2. TURN, or an explicit decision not to

Calls work on a LAN. Two peers behind symmetric NAT — typically different
carrier networks — will fail to connect. The failure is surfaced as a
`CALL FAILED` event rather than ringing forever.

`WebRtcCallService._iceServers` (`client/lib/services/webrtc_call_service.dart`)
is the hook. Note in `SECURITY.md` that a TURN relay sees the encrypted media
stream and both endpoints' addresses; if TURN is added, that section needs
updating to match.

### 3. Forward secrecy

Pairwise keys are static per contact. Compromising a device exposes previously
captured traffic for its conversations, and there is no post-compromise
recovery. This is stated plainly in `SECURITY.md` rather than papered over.

A Double Ratchet over the existing X25519 identities is the fix. `E2EEEngine`
(`client/lib/crypto/e2ee_engine.dart`) is the single place pairwise sealing
happens, so the blast radius is contained. If this is implemented, update the
"What this does not protect against" section — and only then may the code use
ratchet terminology.

### 4. iOS build is broken

`flutter build ios` fails with `Module 'mobile_scanner' not found` from
`GeneratedPluginRegistrant.m`. This is pre-existing and unrelated to recent
work; it survives `flutter clean` plus deleting `ios/Pods`, `Podfile.lock` and
`.symlinks`. `pod install` itself succeeds.

`mobile_scanner: ^6.0.0` pulls in GoogleMLKit. The iOS deployment target is
already 15.5 (both `ios/Podfile` and the Xcode project). Likely a Swift module
or MLKit linkage problem. Android and macOS build fine.

macOS additionally needs a one-time device registration in the Apple developer
account for provisioning; that is an account action, not a code change.

### 5. Team key rotation is best-effort

Unpairing a contact rotates the team key and distributes it pairwise to the
remaining members (`_rotateAndDistributeTeamKey` in `client/lib/main.dart`).
Members who are offline at that moment do not receive it until they reconnect,
and there is currently no mechanism that re-delivers it — the event log records
when distribution was incomplete, and that is all.

Consider re-attempting delivery when a peer reappears, in the same way pending
pairing requests are retried (`_retryPendingPairRequests`).

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
  in their comments.
- Prefer integration tests that stand up both ends over mocks of either.
- Layout bugs are cheap to catch: pump the real widget at 320×568 and assert
  `tester.takeException()` is null. Two overflow bugs shipped before this was
  routine.

## Working in this codebase

- Comments explain *why*, especially where something looks odd — most of them
  record a specific failure. Keep that standard; do not narrate what the code
  already says.
- Edit with explicit string anchors, not computed line offsets. `main.dart` and
  the call view were corrupted several times by index arithmetic that assumed
  member ordering; the analyzer caught it each time, but it cost real effort.
- The work is uncommitted as of this handoff. Check `git status` before starting
  and consider committing the existing state first, so your changes are
  separable from it.
