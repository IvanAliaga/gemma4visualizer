# Gemma4Visualizer

Proxy HTTP liviano escrito en Zig que conecta una interfaz web con [Ollama](https://ollama.com), permitiendo interactuar con **gemma4:e4b** de forma multimodal — texto, imagen y audio nativo.

<details>
<summary>🇬🇧 English</summary>

Lightweight HTTP proxy written in Zig connecting a web frontend to Ollama for multimodal interactions with gemma4:e4b — text, image and native audio.

</details>

<details>
<summary>🇧🇷 Português</summary>

Proxy HTTP leve escrito em Zig que conecta uma interface web ao Ollama para interações multimodais com gemma4:e4b — texto, imagem e áudio nativo.

</details>

---

## Características

- **Chat de texto** — respuestas en streaming vía `/api/chat`
- **Visión** — análisis de imágenes en base64 vía `/api/vision`
- **Audio** — grabación desde el navegador procesada con ffmpeg → WAV → audio nativo de Ollama vía `/api/audio`
- Se ejecuta como un **binario estático único** (~1 MB) sin dependencias en tiempo de ejecución salvo ffmpeg
- Soporte Docker con build multi-etapa (no se necesita el compilador Zig en la imagen final)
- Todo corre **100% local** — sin APIs externas, sin costos, sin datos que salen de tu máquina

## Arquitectura

```
Navegador (public/index.html)
        │
        ▼
Proxy HTTP en Zig (puerto 8080)
        │
        ├─ /api/chat    ──► Ollama /api/chat     (texto, streaming)
        ├─ /api/vision  ──► Ollama /api/generate  (imagen, streaming)
        └─ /api/audio   ──► ffmpeg (WAV) ──► Ollama /api/chat (audio, streaming)
```

## Requisitos

- [Docker](https://www.docker.com/) y Docker Compose
- [Ollama](https://ollama.com) corriendo en tu máquina con el modelo gemma4:e4b descargado

```bash
ollama pull gemma4:e4b
```

> **macOS / Windows**: Ollama debe escuchar en todas las interfaces para que Docker pueda alcanzarlo:
> ```bash
> OLLAMA_HOST=0.0.0.0 ollama serve
> ```
> O configurá `OLLAMA_HOST=0.0.0.0` en tu servicio de Ollama.

## Inicio rápido (Docker)

```bash
git clone https://github.com/IvanAliaga/gemma4visualizer.git
cd gemma4visualizer
docker compose up --build -d
```

Abrí [http://localhost:8090](http://localhost:8090) en el navegador.

## Configuración

| Variable de entorno | Valor por defecto | Descripción |
|---|---|---|
| `OLLAMA_BASE` | `http://host.docker.internal:11434` | URL base de Ollama |

Editá `docker-compose.yml` para cambiar el puerto del host (`8090:8080`) o la URL de Ollama.

## Desarrollo local (sin Docker)

Requisitos: [Zig 0.15.2](https://ziglang.org/download/) y ffmpeg.

```bash
# Instalar ffmpeg (macOS)
brew install ffmpeg

# Compilar y ejecutar
zig build run
```

El servidor arranca en `http://localhost:8080`.

```bash
# Ejecutar tests
zig build test
```

## API

### `GET /api/health`
Estado de conectividad con Ollama.
```json
{"status": "ok", "ollama": "running"}
```

### `POST /api/chat`
Proxy a Ollama `/api/chat`. Acepta cualquier body de chat de Ollama. Responde en streaming NDJSON.

```json
{
  "model": "gemma4:e4b",
  "messages": [{"role": "user", "content": "Hola"}],
  "stream": true
}
```

### `POST /api/vision`
Proxy a Ollama `/api/generate` para análisis de imágenes.

```json
{
  "model": "gemma4:e4b",
  "prompt": "Describí esta imagen",
  "images": ["<base64>"],
  "stream": true
}
```

### `POST /api/audio`
Acepta audio crudo (cualquier formato) en base64. Lo convierte a WAV via ffmpeg y lo envía al pipeline de audio nativo de Ollama.

```json
{
  "model": "gemma4:e4b",
  "text": "¿Qué escuchás?",
  "audio": "<audio en base64>"
}
```

Límite de audio: máximo 30 segundos, convertido internamente a WAV mono 16 kHz.

## Cómo funciona el audio

Ollama detecta si un archivo es audio inspeccionando los magic bytes RIFF/WAVE en el campo `images`. El PCM crudo sin header WAV es interpretado silenciosamente como imagen y falla. Este proxy garantiza el pipeline correcto:

```
Audio del navegador (WebM/Ogg) → ffmpeg → WAV mono 16kHz (header RIFF) → base64 → Ollama
```

## Tests

```bash
zig build test
# 16 tests: parsing JSON, tipos MIME, base64, construcción de requests
```

## Cambiar el modelo

El modelo por defecto es `gemma4:e4b`. Podés cambiarlo por request incluyendo `"model": "tu-modelo"` en el body. El endpoint de audio usa `gemma4:e4b` por defecto si no se especifica modelo.

## Known Issues & Mitigations

El audio con gemma4:e4b tiene bugs activos en Ollama/llama.cpp. Este proxy los mitiga automáticamente.

| Issue | Estado | Mitigación implementada |
|---|---|---|
| [#15333 — Crash intermitente durante forward pass](https://github.com/ollama/ollama/issues/15333) | Abierto | Retry automático recortando 0.5s del audio por intento (cambia el token count y esquiva el error de alineación en los kernels GGML) |
| [#15427 — Sin documentación oficial de audio](https://github.com/ollama/ollama/issues/15427) | Abierto | El proxy fuerza WAV 16kHz mono con header RIFF y ordena las modalidades correctamente |
| [#11798 — Campo `audio` no existe en la API](https://github.com/ollama/ollama/issues/11798) | Abierto | El audio se pasa por el campo `images` con los magic bytes RIFF/WAVE correctos |

El proxy también fuerza `num_ctx=8192` en requests de audio para evitar que los embeddings compitan con el KV cache.

<details>
<summary>🇬🇧 English</summary>

## Known Issues & Mitigations

There are active bugs in Ollama/llama.cpp affecting audio with gemma4:e4b. This proxy mitigates them automatically.

| Issue | Status | Mitigation |
|---|---|---|
| [#15333 — Intermittent crash during forward pass](https://github.com/ollama/ollama/issues/15333) | Open | Auto-retry trimming 0.5s per attempt (changes token count to avoid GGML kernel alignment bug) |
| [#15427 — No official audio documentation](https://github.com/ollama/ollama/issues/15427) | Open | Proxy enforces WAV 16kHz mono with RIFF header and correct modal ordering |
| [#11798 — No `audio` field in the API](https://github.com/ollama/ollama/issues/11798) | Open | Audio is passed through the `images` field with correct RIFF/WAVE magic bytes |

The proxy also forces `num_ctx=8192` on audio requests to prevent embeddings from competing with the KV cache.

</details>

<details>
<summary>🇧🇷 Português</summary>

## Known Issues & Mitigações

Existem bugs ativos no Ollama/llama.cpp afetando o áudio com gemma4:e4b. Este proxy os mitiga automaticamente.

| Issue | Status | Mitigação |
|---|---|---|
| [#15333 — Crash intermitente durante o forward pass](https://github.com/ollama/ollama/issues/15333) | Aberto | Retry automático cortando 0.5s por tentativa (muda o token count para evitar o bug de alinhamento nos kernels GGML) |
| [#15427 — Sem documentação oficial de áudio](https://github.com/ollama/ollama/issues/15427) | Aberto | O proxy força WAV 16kHz mono com header RIFF e ordenação correta das modalidades |
| [#11798 — Campo `audio` não existe na API](https://github.com/ollama/ollama/issues/11798) | Aberto | O áudio é passado pelo campo `images` com os magic bytes RIFF/WAVE corretos |

O proxy também força `num_ctx=8192` em requests de áudio para evitar que os embeddings compitam com o KV cache.

</details>

## Licencia

MIT — ver [LICENSE](LICENSE).

---

<details>
<summary>🇬🇧 Full English documentation</summary>

## Features

- **Text chat** — streaming responses via `/api/chat`
- **Vision** — send images (base64) for analysis via `/api/vision`
- **Audio** — send microphone recordings, processed through ffmpeg → WAV → Ollama native audio via `/api/audio`
- Runs as a **single static binary** (~1 MB) with no runtime dependencies except ffmpeg
- Docker support with multi-stage build (Zig compiler not needed in the final image)
- Runs **100% locally** — no external APIs, no costs, no data leaving your machine

## Architecture

```
Browser (public/index.html)
        │
        ▼
Zig HTTP proxy (port 8080)
        │
        ├─ /api/chat    ──► Ollama /api/chat    (text, streaming)
        ├─ /api/vision  ──► Ollama /api/generate (image, streaming)
        └─ /api/audio   ──► ffmpeg (WAV) ──► Ollama /api/chat (audio, streaming)
```

## Prerequisites

- [Docker](https://www.docker.com/) and Docker Compose
- [Ollama](https://ollama.com) running on your host with gemma4:e4b pulled

```bash
ollama pull gemma4:e4b
```

> **macOS / Windows**: Ollama must listen on all interfaces so Docker can reach it:
> ```bash
> OLLAMA_HOST=0.0.0.0 ollama serve
> ```

## Quick Start (Docker)

```bash
git clone https://github.com/IvanAliaga/gemma4visualizer.git
cd gemma4visualizer
docker compose up --build -d
```

Open [http://localhost:8090](http://localhost:8090).

## Configuration

| Environment variable | Default | Description |
|---|---|---|
| `OLLAMA_BASE` | `http://host.docker.internal:11434` | Ollama base URL |

## Local Development

Requirements: [Zig 0.15.2](https://ziglang.org/download/) and ffmpeg.

```bash
brew install ffmpeg   # macOS
zig build run
zig build test
```

## How audio works

Ollama detects audio by inspecting RIFF/WAVE magic bytes in the `images` field. Raw PCM without a WAV header is silently misinterpreted as an image and fails. This proxy ensures the correct pipeline:

```
Browser audio (WebM/Ogg) → ffmpeg → WAV mono 16kHz (RIFF header) → base64 → Ollama
```

</details>

<details>
<summary>🇧🇷 Documentação completa em Português</summary>

## Características

- **Chat de texto** — respostas em streaming via `/api/chat`
- **Visão** — envie imagens (base64) para análise via `/api/vision`
- **Áudio** — grave pelo navegador, processado com ffmpeg → WAV → áudio nativo do Ollama via `/api/audio`
- Executa como um **binário estático único** (~1 MB) sem dependências em tempo de execução além do ffmpeg
- Suporte Docker com build multi-estágio (compilador Zig não necessário na imagem final)
- Executa **100% localmente** — sem APIs externas, sem custos, sem dados saindo da sua máquina

## Arquitetura

```
Navegador (public/index.html)
        │
        ▼
Proxy HTTP em Zig (porta 8080)
        │
        ├─ /api/chat    ──► Ollama /api/chat    (texto, streaming)
        ├─ /api/vision  ──► Ollama /api/generate (imagem, streaming)
        └─ /api/audio   ──► ffmpeg (WAV) ──► Ollama /api/chat (áudio, streaming)
```

## Pré-requisitos

- [Docker](https://www.docker.com/) e Docker Compose
- [Ollama](https://ollama.com) rodando na sua máquina com o modelo gemma4:e4b baixado

```bash
ollama pull gemma4:e4b
```

> **macOS / Windows**: O Ollama deve escutar em todas as interfaces para que o Docker possa acessá-lo:
> ```bash
> OLLAMA_HOST=0.0.0.0 ollama serve
> ```

## Início Rápido (Docker)

```bash
git clone https://github.com/IvanAliaga/gemma4visualizer.git
cd gemma4visualizer
docker compose up --build -d
```

Abra [http://localhost:8090](http://localhost:8090) no navegador.

## Configuração

| Variável de ambiente | Padrão | Descrição |
|---|---|---|
| `OLLAMA_BASE` | `http://host.docker.internal:11434` | URL base do Ollama |

## Desenvolvimento Local

Requisitos: [Zig 0.15.2](https://ziglang.org/download/) e ffmpeg.

```bash
brew install ffmpeg   # macOS
zig build run
zig build test
```

## Como o áudio funciona

O Ollama detecta áudio inspecionando os magic bytes RIFF/WAVE no campo `images`. PCM bruto sem header WAV é interpretado silenciosamente como imagem e falha. Este proxy garante o pipeline correto:

```
Áudio do navegador (WebM/Ogg) → ffmpeg → WAV mono 16kHz (header RIFF) → base64 → Ollama
```

</details>
