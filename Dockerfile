# ── Stage 1: Build Zig ────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS builder

ARG ZIG_VERSION=0.15.2

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) ZIG_ARCH="x86_64" ;; \
      arm64) ZIG_ARCH="aarch64" ;; \
      *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt && \
    ln -s /opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ ./src/
RUN zig build -Doptimize=ReleaseFast

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim

# ffmpeg convierte cualquier formato de audio a WAV mono 16kHz (con header RIFF)
# Ollama v0.20+ detecta el header RIFF y procesa el audio nativamente en gemma4
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/zig-out/bin/gemma4visualizer ./gemma4visualizer
COPY public/ ./public/

EXPOSE 8080
ENV OLLAMA_BASE=http://host.docker.internal:11434
CMD ["./gemma4visualizer"]
