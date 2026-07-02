# syntax=docker/dockerfile:1
#
# Claude Apps Gateway image.
#
# Builds a minimal glibc image around the native `claude` Linux binary and runs
# it as `claude gateway`. The binary is downloaded from the pinned release,
# verified against the GPG-signed manifest, then copied into a slim runtime.
#
# Build:
#   docker build --build-arg CLAUDE_VERSION=2.1.196 \
#                --build-arg TARGETARCH=amd64 \
#                -t claude-gateway:2.1.196 .
#
# The gateway server requires the NATIVE binary (not the Node wrapper) and a
# glibc-based image. See https://code.claude.com/docs/en/claude-apps-gateway-deploy

# ---- stage 1: download + GPG-verify the native binary --------------------------
FROM debian:stable-slim AS fetch

ARG CLAUDE_VERSION=2.1.196
# Docker's TARGETARCH is amd64/arm64; the release uses linux-x64/linux-arm64.
ARG TARGETARCH=amd64

ARG RELEASES=https://downloads.claude.ai/claude-code-releases
ARG KEY_URL=https://downloads.claude.ai/keys/claude-code.asc
# Anthropic Claude Code Release Signing key fingerprint (verify-on-import).
ARG KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) PLATFORM="linux-x64" ;; \
      arm64) PLATFORM="linux-arm64" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    # 1. Import + verify the release signing key fingerprint.
    curl -fsSL "${KEY_URL}" | gpg --import; \
    gpg --batch --with-colons --fingerprint security@anthropic.com \
      | grep -q "${KEY_FPR}" || { echo "release signing key fingerprint mismatch" >&2; exit 1; }; \
    # 2. Fetch manifest + detached signature and verify.
    curl -fsSLO "${RELEASES}/${CLAUDE_VERSION}/manifest.json"; \
    curl -fsSLO "${RELEASES}/${CLAUDE_VERSION}/manifest.json.sig"; \
    gpg --batch --verify manifest.json.sig manifest.json; \
    # 3. Download the binary and check its sha256 against the verified manifest.
    #    Extract the checksum for our platform: match the platform key (the
    #    trailing quote in "${PLATFORM}" avoids matching "${PLATFORM}-musl"),
    #    then pull the first 64-hex checksum that follows.
    curl -fsSL "${RELEASES}/${CLAUDE_VERSION}/${PLATFORM}/claude" -o claude; \
    EXPECTED="$(grep -A4 "\"${PLATFORM}\":" manifest.json | grep -oE '[0-9a-f]{64}' | head -1)"; \
    test -n "${EXPECTED}" || { echo "could not find checksum for ${PLATFORM}" >&2; exit 1; }; \
    echo "${EXPECTED}  claude" | sha256sum -c -; \
    chmod +x claude

# ---- stage 2: runtime ----------------------------------------------------------
FROM debian:stable-slim AS runtime

# ripgrep is bundled in the binary; ca-certificates needed for OIDC/Bedrock TLS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /work/claude /usr/local/bin/claude

# Optionally trust extra CAs (e.g. a self-hosted OTEL collector's self-signed
# CA). The gateway verifies telemetry-forward TLS against this system trust
# store and has no per-destination CA option, so a self-signed collector cert
# must be trusted here. build-and-push.sh stages COLLECTOR_CA_PEM into extra-ca/;
# the directory always exists (extra-ca/.keep) so the build works with no extra
# CA too. Runs as root before the USER switch.
COPY extra-ca/ /usr/local/share/ca-certificates/extra/
RUN update-ca-certificates

# Minimal images have no writable home; the gateway needs a writable config dir.
ENV CLAUDE_CONFIG_DIR=/tmp/.claude
# Strict egress posture: don't phone home for analytics/update checks.
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Run as an unprivileged user with a writable /tmp.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin gateway
USER 10001

COPY --chown=10001:10001 entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
