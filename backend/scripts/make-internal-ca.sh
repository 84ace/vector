#!/usr/bin/env bash
#
# Provisions an internal CA and a relay server certificate for a Vector C2 node
# that has no route to the public internet.
#
# An isolated deployment cannot use Let's Encrypt — there is no ACME challenge
# it can answer — so the CA is generated here and pinned into the client build.
# For a node with a public DNS name, do not use this: get a publicly-trusted
# certificate instead and leave RELAY_CA_PEM_BASE64 unset. See DEPLOYMENT.md.
#
# Usage:
#   ./make-internal-ca.sh <output-dir> <hostname-or-ip> [more-hostnames-or-ips...]
#
# Example:
#   ./make-internal-ca.sh ./certs nas.local 192.168.1.20
#
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <output-dir> <hostname-or-ip> [more...]" >&2
  exit 64
fi

OUT_DIR="$1"; shift
CA_DAYS="${CA_DAYS:-3650}"
LEAF_DAYS="${LEAF_DAYS:-825}"

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

# Build the SAN list. Every name the client might dial has to appear here:
# verification matches against the SAN, and a certificate with only a CN is
# rejected outright by every current TLS stack.
san=""
for host in "$@"; do
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$host" == *:* ]]; then
    san+="IP:${host},"
  else
    san+="DNS:${host},"
  fi
done
san="${san%,}"

echo "==> Root CA (${CA_DAYS} days)"
openssl req -x509 -newkey rsa:4096 -sha256 -days "$CA_DAYS" -nodes \
  -keyout ca.key -out ca.crt \
  -subj "/CN=Vector C2 Internal CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

echo "==> Server key and CSR"
openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout node.key -out node.csr \
  -subj "/CN=$1" 2>/dev/null

# extendedKeyUsage=serverAuth is not optional: BoringSSL — which is what the
# Dart client's TLS stack is — rejects a chain whose leaf does not assert it.
echo "==> Signing server certificate (${LEAF_DAYS} days), SAN: ${san}"
openssl x509 -req -in node.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out node.crt -days "$LEAF_DAYS" -sha256 \
  -extfile <(printf 'subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$san") 2>/dev/null

rm -f node.csr ca.srl

chmod 600 ca.key node.key
chmod 644 ca.crt node.crt

echo
echo "Wrote to $(pwd):"
echo "  ca.crt   - pin this into the client build (public, safe to distribute)"
echo "  ca.key   - KEEP OFFLINE. Anything holding this can mint a node cert."
echo "  node.crt - serve as TLS_CERT_FILE"
echo "  node.key - serve as TLS_KEY_FILE (never leaves the node)"
echo
echo "Node:"
echo "  TLS_CERT_FILE=$(pwd)/node.crt TLS_KEY_FILE=$(pwd)/node.key ./node_server"
echo
echo "Client — pin the CA at build time:"
echo "  flutter build apk \\"
echo "    --dart-define=CLOUD_MESH_NODE_URL=https://$1:8443 \\"
echo "    --dart-define=RELAY_CA_PEM_BASE64=$(base64 < ca.crt | tr -d '\n')"
