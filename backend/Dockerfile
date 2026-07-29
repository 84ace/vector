# Build Stage
FROM golang:1.22-alpine AS builder

WORKDIR /app

# Copy dependency files
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY cmd/ ./cmd/
COPY pkg/ ./pkg/

# Build statically linked Go binary
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /app/node_server ./cmd/node/main.go

# Minimal Runtime Stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates tzdata

# Run as an unprivileged user: the node accepts connections from the network and
# has no need for root inside the container.
RUN addgroup -S vector && adduser -S -G vector vector

WORKDIR /app

COPY --from=builder /app/node_server /app/node_server

USER vector

EXPOSE 8080

ENV PORT=8080
ENV NODE_ID=nas-local-node-8080

# Set TLS_CERT_FILE and TLS_KEY_FILE to serve wss:// instead of plaintext ws://,
# and ALLOWED_ORIGINS if browser clients need to connect.

HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/node_server"]
