# Vector C2 — deploying a relay node with TLS

Message bodies are end-to-end encrypted whether or not the relay uses TLS. What
TLS protects is the **routing metadata**: who talks to whom, when, and how much.
For this application that is itself sensitive, so the client refuses plaintext to
anything routable by default.

Read `SECURITY.md` for the threat model. This document is only about getting a
node deployed and the client configured to trust it.

## Which path applies to you

| Deployment | Certificate | Client build flag |
|---|---|---|
| Public node, real DNS name | Publicly-trusted (Let's Encrypt, or your existing CA that chains to a public root) | none |
| Isolated / LAN node | Internal CA, generated with `backend/scripts/make-internal-ca.sh` | `--dart-define=RELAY_CA_PEM_BASE64=…` |
| LAN node, no TLS | none | none — permitted to private addresses only |

The middle row is the one that needs explaining, so it gets the most space below.

## The transport policy

`TRANSPORT_POLICY` is a build-time define on the client. It replaced a
`require_tls` preference that defaulted to false and that no screen ever wrote —
so the check it guarded could never fire.

| Value | Behaviour |
|---|---|
| `private` (default) | `https://` anywhere. Plaintext only to loopback, RFC1918/CGNAT/link-local, IPv6 ULA, and the private-use name suffixes (`.local`, `.lan`, `.internal`, `.intranet`, `.private`, `.home.arpa`) or a bare single-label host. |
| `tls-only` | `https://` only. Even a LAN node must present a certificate. |
| `any` | Plaintext to anything. See "split-horizon DNS" below. |

A seed node skipped by this policy is reported in the operator's event log.
Silently dropping it made a misconfigured deployment look identical to an
outage.

Classification is **syntactic** — no DNS lookup — so whoever answers the query
cannot change the decision. The consequence is that a dotted name is treated as
public even if it resolves to a LAN address. If you run split-horizon DNS
(`c2.example.com` → `192.168.1.20` internally), either use a private-use name,
serve TLS, or set `TRANSPORT_POLICY=any` deliberately.

## Path A — public node with a publicly-trusted certificate

Nothing to configure on the client: the platform root store already trusts it.

Obtain a certificate for the node's DNS name however you normally would, then:

```bash
mkdir -p backend/certs
cp /etc/letsencrypt/live/c2.example.com/fullchain.pem backend/certs/node.crt
cp /etc/letsencrypt/live/c2.example.com/privkey.pem   backend/certs/node.key
cd backend && docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
```

Build the client pointing at it:

```bash
cd client && flutter build apk \
  --dart-define=CLOUD_MESH_NODE_URL=https://c2.example.com:8443
```

Certificates expire. Renewal has to restart or signal the node — it reads the
certificate once at startup and does not watch the file.

### Variant: TLS terminated by an existing reverse proxy

If the node lives behind a reverse proxy that already does TLS for other
services on the same box, it is simpler to let it terminate TLS for this node
too rather than run `docker-compose.tls.yml` and manage a second certificate
and a second open port. The backend stays on its plain `docker-compose.yml`
(`ws://` on 8080, LAN-only), and the proxy forwards to it.

This is how the `nas.local` deployment actually runs, fronted by an existing
`nginx` container that already serves several other `*.84ace.com` subdomains:

```nginx
server {
    listen 443 ssl;
    server_name c2.84ace.com;

    ssl_certificate     /etc/letsencrypt/live/c2.84ace.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/c2.84ace.com/privkey.pem;

    location / {
        proxy_pass http://192.168.0.130:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # The relay protocol is a long-lived WebSocket (telemetry every 4s per
        # operator, plus call signalling), not a request/response API.
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 86400;
    }
}
```

Client build points at the proxy's hostname with no port — same as any other
Path A deployment, and still no CA to pin:

```bash
cd client && flutter build apk \
  --dart-define=CLOUD_MESH_NODE_URL=https://c2.84ace.com \
  --dart-define=TRANSPORT_POLICY=tls-only
```

**Getting the certificate hit a real snag worth recording.** `84ace.com` is a
Cloudflare zone whose `*` record is a CNAME to a TP-Link DDNS hostname
(`84acenas.tplinkdns.com`), kept current by a DDNS client on the DSL modem.
That hostname's own nameservers (`ns{1,2,4,5}.tplinkdns.com`) answer
inconsistently across resolvers — direct queries mostly succeeded, but Let's
Encrypt's multi-perspective validation, which checks from several vantage
points at once, hit `NXDOMAIN` and `SERVFAIL` from different ones on the same
name a few seconds apart. HTTP-01 (`certbot certonly --webroot`) depends on
that CNAME chain resolving everywhere at once, so it failed twice before we
gave up on it.

DNS-01 against Cloudflare directly sidesteps this: the challenge is a TXT
record written straight into the Cloudflare zone, which Let's Encrypt then
checks against Cloudflare's own nameservers — it never has to follow the CNAME
into the flaky TP-Link hop.

```bash
docker run --rm \
  -v /home/acea/Documents/nas-local/config/letsencrypt:/etc/letsencrypt \
  certbot/dns-cloudflare certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  -d c2.84ace.com --key-type ecdsa -n
```

`cloudflare.ini` holds a Cloudflare API token scoped to `Zone / DNS / Edit` on
the `84ace.com` zone only (not a global key), `chmod 600`, one line:
`dns_cloudflare_api_token = ...`. It lives alongside the other Let's Encrypt
state on that box rather than in this repo. Whoever renews this certificate
next should use `dns-cloudflare`, not the webroot flow the other subdomains on
that box use — the DDNS flakiness above is not something that resolved itself,
it is a property of the DDNS provider.

## Path B — isolated node with an internal CA

An isolated network cannot use Let's Encrypt: there is no ACME challenge it can
answer. So generate a CA, issue the node a certificate from it, and pin the CA
into the client build.

```bash
cd backend
./scripts/make-internal-ca.sh ./certs nas.local 192.168.1.20
```

Pass **every** name or address a client might dial. Verification matches against
the SAN list, and a certificate carrying only a CN is rejected by every current
TLS stack.

That writes four files into `backend/certs/`:

| File | Handling |
|---|---|
| `ca.crt` | Public. Pin into the client build. |
| `ca.key` | **Keep offline.** Anything holding it can mint a certificate for any node. |
| `node.crt` | Served as `TLS_CERT_FILE`. |
| `node.key` | Served as `TLS_KEY_FILE`. Never leaves the node. |

Start the node:

```bash
cd backend && docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
```

Build the client with the CA pinned:

```bash
cd client && flutter build apk \
  --dart-define=NAS_MESH_NODE_URL=https://nas.local:8443 \
  --dart-define=RELAY_CA_PEM_BASE64="$(base64 < ../backend/certs/ca.crt | tr -d '\n')"
```

The script prints this line for you, filled in.

### Why the CA has to be pinned into the build

The client's HTTP and WebSocket stack is `dart:io`, which does not go through
NSURLSession or Android's HTTP stack. Consequences:

- Installing the CA as a device profile (iOS) or user certificate (Android) does
  **not** make the client trust it. The anchor has to be handed to the process.
- Equally, iOS App Transport Security and Android's `usesCleartextTraffic` do
  not apply, which is why plaintext to a LAN node works at all. The client's own
  transport policy is the control, not the platform's.

The pinned CA is added *alongside* the platform roots, not instead of them, so a
second seed node with a public certificate keeps working.

If `RELAY_CA_PEM_BASE64` will not parse, the app shows a blocking error and
refuses to start rather than quietly falling back to platform roots — which
would leave every pinned node looking unreachable with nothing saying why.

### Two things that will waste your afternoon

Both were hit while writing this, and the script already handles them:

- **A self-signed leaf certificate does not work as its own trust anchor.**
  `openssl req -x509` with `CA:TRUE` still fails with
  `CERTIFICATE_VERIFY_FAILED: application verification failure`. Use a real
  two-tier chain: root CA, then a leaf signed by it.
- **The leaf must assert `extendedKeyUsage=serverAuth`.** BoringSSL — which is
  what `dart:io` uses — rejects the chain without it.

## Path C — LAN node without TLS

Permitted by the default policy to a private address, and it is a legitimate
choice for an isolated network: there is no path between the two devices for an
observer to sit on that isn't already inside the perimeter.

What is exposed to anything on that subnet: which operator IDs are talking, when,
and message sizes. Bodies stay encrypted. The node logs a startup warning saying
exactly this.

```bash
cd backend && docker compose up -d
```

## Verifying a TLS deployment

Run the node, then check each layer separately — that is how you tell a
certificate problem from a routing problem.

The certificate serves and chains correctly:

```bash
curl -sS --cacert backend/certs/ca.crt https://nas.local:8443/ping
```

The same request **without** the CA must fail. If it succeeds, the certificate is
publicly trusted and you do not need to pin anything:

```bash
curl -sS https://nas.local:8443/ping
```

The full client stack — handshake, routing, signing and sealing over `wss://`:

```bash
cd client && RELAY_URL=https://nas.local:8443 \
  RELAY_CA_FILE=../backend/certs/ca.crt \
  flutter test test/live_relay_test.dart
```

Omitting `RELAY_CA_FILE` there should fail with a TLS diagnostic, not a timeout.
A timeout means something other than trust is wrong.

## Call path (WebRTC ICE)

Call media is DTLS-SRTP directly between the two devices and never passes through
the relay, so none of this affects confidentiality of the call itself. It only
affects how a path between the two devices is found — and who learns about it.

| Define | Default | Effect |
|---|---|---|
| `STUN_SERVERS` | Google's public STUN | Discovers the device's public address. Comma-separated; empty disables STUN. |
| `TURN_URLS` | *empty* | Relays media when no direct path exists. Comma-separated. |
| `TURN_USERNAME`, `TURN_CREDENTIAL` | *empty* | Long-term TURN credentials. |

**TURN is off by default and that is a decision, not an omission.** A call between
two peers both behind symmetric NAT fails visibly — a `CALL FAILED` event — rather
than silently relaying media through a third party.

If you enable it, understand what you are accepting: a TURN relay sees both
endpoints' addresses and the full media stream. The stream stays encrypted
end-to-end so the relay cannot listen to the call, but it learns who called whom,
for how long, and from where. STUN candidates are always offered ahead of relayed
ones, so TURN only carries a call when nothing direct works. The app writes an
advisory naming the relay into the operator's event log.

For an isolated deployment, turn STUN off as well:

```bash
flutter build apk --dart-define=STUN_SERVERS=
```

The public servers are unreachable on such a network anyway, and leaving them
configured only adds candidate-gathering delay to every call. With STUN off,
host candidates carry the call, which is all a LAN needs.

## Building the client for iOS

`flutter build ios` works for the device, profile and simulator configurations.
Two environment notes, both of which have cost time before:

- **`pod install` needs a UTF-8 locale.** Under Ruby 4.x, CocoaPods 1.16 raises
  `Unicode Normalization not appropriate for ASCII-8BIT` if `LANG` is unset —
  from a bare shell or a CI runner, for instance. Export it first:

  ```bash
  export LANG=en_US.UTF-8
  ```

- **Simulator builds need `mobile_scanner` 7.x or newer.** 6.x excluded `arm64`
  for `iphonesimulator` (it pulled in GoogleMLKit), so the app built as x86_64
  only and `simctl install` failed with `Failed to find matching arch` on any
  Apple Silicon iOS 26+ simulator, which are arm64-only. 7.x uses Apple's Vision
  API, ships a universal simulator slice, and removes the MLKit pods — release
  builds dropped from 52.2 MB to 32.7 MB. Do not downgrade it.

To run on a simulator:

```bash
xcrun simctl boot "iPhone 17 Pro" && open -a Simulator
flutter run                     # or: flutter build ios --simulator
```

`flutter run` handles build, install and launch. To do it by hand:

```bash
flutter build ios --simulator
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
xcrun simctl launch booted com.tactical.vector
```

The simulator has no camera, so QR scanning cannot be exercised there — use the
"paste pairing code" field on the pairing screen, or a physical device.

## Notes

- `ALLOWED_ORIGINS` only matters for browser clients. Native clients send no
  `Origin` header and are unaffected; setting it refuses a hostile web page.
- The TLS overlay replaces the container healthcheck. The base one probes
  `http://` and would mark a perfectly healthy TLS node unhealthy, restarting it
  in a loop. The overlay's `--no-check-certificate` is not a weakening: it runs
  inside the container against its own listener to prove the process is alive,
  and authenticates nothing.
- The node reads `TLS_CERT_FILE` / `TLS_KEY_FILE` once at startup. There is no
  hot reload; renewal must restart it.
- There is still **no node-to-node authentication**. TLS protects client-to-node
  metadata. `/announce` accepts peer records from private addresses only, and
  federating across untrusted networks would need node identity keys, which is
  not implemented.
