# Gemma4Visualizer

A lightweight HTTP proxy written in Zig that connects a web frontend to [Ollama](https://ollama.com), enabling multimodal interactions with **gemma4:e4b** — including text chat, image analysis, and native audio understanding.

## Features

- **Text chat** — streaming responses via `/api/chat`
- **Vision** — send images (base64) for analysis via `/api/vision`
- **Audio** — send microphone recordings, processed through ffmpeg → WAV → Ollama native audio via `/api/audio`
- Runs as a **single static binary** (~1 MB) with no runtime dependencies except ffmpeg
- Docker support with multi-stage build (Zig compiler not needed in the final image)

## Architecture

```
Browser (public/index.html)
        │
        ▼
Zig HTTP proxy (port 8080)
        │
        ├─ /api/chat    ──► Ollama /api/chat   (text, streaming)
        ├─ /api/vision  ──► Ollama /api/generate (image, streaming)
        └─ /api/audio   ──► ffmpeg (WAV) ──► Ollama /api/chat (audio, streaming)
```

## Prerequisites

- [Docker](https://www.docker.com/) and Docker Compose
- [Ollama](https://ollama.com) running on your host machine with the gemma4:e4b model pulled

```bash
ollama pull gemma4:e4b
```

> **macOS / Windows**: Ollama must listen on all interfaces so Docker can reach it:
> ```bash
> OLLAMA_HOST=0.0.0.0 ollama serve
> ```
> Or set `OLLAMA_HOST=0.0.0.0` in your Ollama service configuration.

## Quick Start (Docker)

```bash
git clone https://github.com/<you>/gemma4visualizer.git
cd gemma4visualizer
docker compose up --build -d
```

Open [http://localhost:8090](http://localhost:8090) in your browser.

## Configuration

| Environment variable | Default | Description |
|---|---|---|
| `OLLAMA_BASE` | `http://host.docker.internal:11434` | Ollama base URL |

Edit `docker-compose.yml` to change the host port (`8090:8080`) or the Ollama URL.

## Local Development (without Docker)

Requirements: [Zig 0.15.2](https://ziglang.org/download/) and ffmpeg.

```bash
# Install ffmpeg (macOS)
brew install ffmpeg

# Build and run
zig build run
```

Server starts at `http://localhost:8080`.

```bash
# Run tests
zig build test
```

## API Endpoints

### `GET /api/health`
Returns Ollama connectivity status.
```json
{"status": "ok", "ollama": "running"}
```

### `POST /api/chat`
Proxy to Ollama `/api/chat`. Accepts any Ollama chat request body. Streams NDJSON.

```json
{
  "model": "gemma4:e4b",
  "messages": [{"role": "user", "content": "Hello"}],
  "stream": true
}
```

### `POST /api/vision`
Proxy to Ollama `/api/generate` for image analysis.

```json
{
  "model": "gemma4:e4b",
  "prompt": "Describe this image",
  "images": ["<base64>"],
  "stream": true
}
```

### `POST /api/audio`
Accepts raw audio (any format) as base64. Converts to WAV via ffmpeg and sends to Ollama's native audio pipeline.

```json
{
  "model": "gemma4:e4b",
  "text": "What do you hear?",
  "audio": "<base64 encoded audio>"
}
```

Audio limits: max 30 seconds, converted to mono 16 kHz WAV internally.

## How audio works

Ollama's gemma4 detects audio by inspecting the RIFF/WAVE magic bytes in the `images` field. Raw PCM without a WAV header is silently misinterpreted as an image and fails. This proxy ensures the correct pipeline:

```
Browser audio (WebM/Ogg) → ffmpeg → WAV mono 16kHz (RIFF header) → base64 → Ollama
```

## Changing the model

The default model is `gemma4:e4b`. You can change it per request by including `"model": "your-model"` in the request body. The audio endpoint defaults to `gemma4:e4b` if no model is specified.
