//! Gemma4Visualizer — Proxy inteligente entre frontend HTML y Ollama
//!
//! Endpoints:
//!   GET  /             → sirve public/index.html
//!   GET  /api/health   → health check de Ollama
//!   POST /api/chat     → proxy texto a Ollama
//!   POST /api/vision   → proxy imagen (base64) a Ollama
//!   POST /api/audio    → proxy audio con 5 capas de mitigación
//!   GET  /*            → sirve archivos estáticos de ./public/

const std = @import("std");
const audio = @import("audio.zig");

// ─── Configuración ───────────────────────────────────────────────────────────

const PORT: u16 = 8080;
const MAX_CONNECTIONS = 64;
const MAX_REQUEST_SIZE = 64 * 1024 * 1024; // 64 MB (para audio)
const MAX_HEADER_SIZE = 16 * 1024;

// Ollama: configurable via env var OLLAMA_BASE (default: localhost para dev,
// host.docker.internal para Docker)
var OLLAMA_BASE: []const u8 = "http://host.docker.internal:11434";

// Tiempo que Ollama mantiene el modelo cargado en RAM tras el último request.
// "0" = descargar inmediatamente; "5m" = 5 minutos; "-1" = nunca descargar.
// Definido en audio.zig como fuente de verdad única.
const OLLAMA_KEEP_ALIVE: []const u8 = audio.KEEP_ALIVE;

// ─── Tipos ───────────────────────────────────────────────────────────────────

const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
    content_type: []const u8,
};

// ─── Main ────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Leer Ollama base de env var
    if (std.process.getEnvVarOwned(allocator, "OLLAMA_BASE")) |base| {
        OLLAMA_BASE = base;
    } else |_| {}

    // Verificar ffmpeg al arranque
    audio.verifyFfmpeg(allocator) catch {
        std.log.warn("⚠️  ffmpeg no encontrado — /api/audio no funcionará", .{});
    };

    const addr = try std.net.Address.parseIp("0.0.0.0", PORT);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("🚀 Gemma4Visualizer → http://0.0.0.0:{d}", .{PORT});
    std.log.info("📡 Ollama → {s}", .{OLLAMA_BASE});

    while (true) {
        const conn = server.accept() catch |err| {
            std.log.err("accept: {}", .{err});
            continue;
        };
        _ = std.Thread.spawn(.{}, handleConn, .{ conn, allocator }) catch |err| {
            std.log.err("thread: {}", .{err});
            conn.stream.close();
        };
    }
}

// ─── Manejo de conexión (hilo por conexión) ──────────────────────────────────

fn handleConn(conn: std.net.Server.Connection, parent_alloc: std.mem.Allocator) void {
    defer conn.stream.close();

    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    const req = readRequest(conn.stream, allocator) catch |err| {
        std.log.err("readRequest: {}", .{err});
        return;
    };

    route(conn.stream, req, allocator) catch |err| {
        std.log.err("route {s}: {}", .{ req.path, err });
        sendError(conn.stream, 500, "Internal server error") catch {};
    };
}

// ─── Parser HTTP mínimo ──────────────────────────────────────────────────────

fn readRequest(stream: std.net.Stream, allocator: std.mem.Allocator) !HttpRequest {
    var buf = try allocator.alloc(u8, MAX_REQUEST_SIZE);
    var total: usize = 0;

    // Leer hasta encontrar \r\n\r\n (fin de headers)
    var header_end: ?usize = null;
    while (total < buf.len) {
        const n = try stream.read(buf[total..@min(total + 4096, buf.len)]);
        if (n == 0) return error.ConnectionClosed;
        total += n;

        if (header_end == null) {
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |pos| {
                header_end = pos;
            }
        }

        if (header_end) |he| {
            const header_section = buf[0..he];

            // Parsear Content-Length
            var content_length: usize = 0;
            var content_type: []const u8 = "";
            var hdr_lines = std.mem.splitSequence(u8, header_section, "\r\n");
            _ = hdr_lines.next(); // request line

            while (hdr_lines.next()) |line| {
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                    const val = std.mem.trim(u8, line[15..], " ");
                    content_length = std.fmt.parseInt(usize, val, 10) catch 0;
                } else if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
                    content_type = std.mem.trim(u8, line[13..], " ");
                }
            }

            const body_start = he + 4;
            // Leer body completo si faltan bytes
            while ((total - body_start) < content_length) {
                const remaining = content_length - (total - body_start);
                const to_read = @min(remaining, buf.len - total);
                if (to_read == 0) break;
                const n2 = try stream.read(buf[total .. total + to_read]);
                if (n2 == 0) break;
                total += n2;
            }

            // Parsear request line
            var req_line = std.mem.splitScalar(u8, buf[0..he], '\n');
            const first_line = std.mem.trimRight(u8, req_line.next() orelse "", "\r");
            var parts = std.mem.splitScalar(u8, first_line, ' ');
            const method = parts.next() orelse return error.BadRequest;
            const path_raw = parts.next() orelse return error.BadRequest;
            const path = if (std.mem.indexOfScalar(u8, path_raw, '?')) |q|
                path_raw[0..q]
            else
                path_raw;

            const body = buf[body_start..@min(body_start + content_length, total)];

            return .{
                .method = method,
                .path = path,
                .body = body,
                .content_type = content_type,
            };
        }
    }
    return error.RequestTooLarge;
}

// ─── Router ──────────────────────────────────────────────────────────────────

fn route(stream: std.net.Stream, req: HttpRequest, allocator: std.mem.Allocator) !void {
    if (std.mem.eql(u8, req.path, "/") or std.mem.eql(u8, req.path, "/index.html")) {
        return serveFile(stream, "public/index.html", allocator);
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/api/health")) {
        return handleHealth(stream, allocator);
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/api/chat")) {
        return handleProxy(stream, "/api/chat", req.body, allocator);
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/api/vision")) {
        return handleProxy(stream, "/api/generate", req.body, allocator);
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/api/audio")) {
        return handleAudio(stream, req.body, allocator);
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.startsWith(u8, req.path, "/")) {
        // Intentar servir archivo estático
        const file_path = try std.fmt.allocPrint(allocator, "public{s}", .{req.path});
        serveFile(stream, file_path, allocator) catch {
            try sendError(stream, 404, "Not found");
        };
        return;
    }
    try sendError(stream, 404, "Not found");
}

// ─── GET /api/health ─────────────────────────────────────────────────────────

fn handleHealth(stream: std.net.Stream, allocator: std.mem.Allocator) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/api/tags", .{OLLAMA_BASE});
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
    }) catch {
        return sendJson(stream, 503, "{\"status\":\"ollama_unreachable\"}");
    };

    if (result.status == .ok) {
        try sendJson(stream, 200, "{\"status\":\"ok\",\"ollama\":\"running\"}");
    } else {
        try sendJson(stream, 503, "{\"status\":\"ollama_error\"}");
    }
}

// ─── POST /api/chat y /api/vision — proxy con streaming ──────────────────────

fn handleProxy(
    stream: std.net.Stream,
    ollama_path: []const u8,
    body: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ OLLAMA_BASE, ollama_path });

    // Inyectar keep_alive para que Ollama descargue el modelo tras el timeout
    const trimmed = std.mem.trimRight(u8, body, " \t\r\n");
    const body_out = if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '}')
        try std.fmt.allocPrint(allocator, "{s},\"keep_alive\":\"{s}\"}}", .{ trimmed[0 .. trimmed.len - 1], OLLAMA_KEEP_ALIVE })
    else
        body;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
    defer req.deinit();

    // Enviar body
    req.transfer_encoding = .{ .content_length = body_out.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body_out);
    try bw.end();
    try req.connection.?.flush();

    // Leer cabeceras de respuesta de Ollama
    var redirect_buf: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    // Cabeceras de respuesta chunked al cliente
    try stream.writeAll("HTTP/1.1 200 OK\r\n");
    try stream.writeAll("Content-Type: application/x-ndjson\r\n");
    try stream.writeAll("Transfer-Encoding: chunked\r\n");
    try stream.writeAll("Cache-Control: no-cache\r\n");
    try stream.writeAll("Access-Control-Allow-Origin: *\r\n");
    try stream.writeAll("\r\n");

    // Pipe de Ollama → cliente en chunks
    var transfer_buf: [4096]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    var out_buf: [4096]u8 = undefined;
    while (true) {
        const n = body_reader.readSliceShort(&out_buf) catch break;
        if (n == 0) break;
        try writeChunk(stream, out_buf[0..n]);
    }
    try writeChunkEnd(stream);
}

// ─── POST /api/audio ─────────────────────────────────────────────────────────
// Pipeline: audio base64 → ffmpeg WAV → WAV base64 en "images" → gemma4:e4b

fn handleAudio(stream: std.net.Stream, body: []const u8, allocator: std.mem.Allocator) !void {
    const model = jsonField(body, "model") orelse "gemma4:e4b";
    const text = jsonField(body, "text") orelse "Describe what you hear";
    const audio_b64 = jsonField(body, "audio") orelse {
        return sendError(stream, 400, "Missing 'audio' field");
    };

    // Decodificar base64 → bytes crudos del audio
    const decoder = std.base64.standard.Decoder;
    const raw_len = try decoder.calcSizeForSlice(audio_b64);
    const raw_bytes = try allocator.alloc(u8, raw_len);
    try decoder.decode(raw_bytes, audio_b64);

    // CAPA 1 — ffmpeg: convertir a WAV mono 16kHz (con header RIFF)
    const wav_bytes = audio.normalizeAudio(raw_bytes, allocator) catch |err| {
        std.log.err("ffmpeg: {}", .{err});
        return sendError(stream, 500, "Audio normalization failed");
    };

    const dur_s = @as(f32, @floatFromInt(wav_bytes.len)) / (16000.0 * 2.0); // 16kHz 16-bit
    std.log.info("🎤 Audio WAV listo: {d:.1}s ({d} bytes) → enviando a Ollama", .{ dur_s, wav_bytes.len });

    // CAPA 2 — Codificar WAV a base64
    const wav_b64 = try audio.toBase64(wav_bytes, allocator);

    // Construir request para Ollama (WAV base64 en campo "images")
    const ollama_body = try audio.buildOllamaAudioRequest(model, text, wav_b64, allocator);

    // Iniciar respuesta chunked al cliente
    try stream.writeAll("HTTP/1.1 200 OK\r\n");
    try stream.writeAll("Content-Type: application/x-ndjson\r\n");
    try stream.writeAll("Transfer-Encoding: chunked\r\n");
    try stream.writeAll("Cache-Control: no-cache\r\n");
    try stream.writeAll("Access-Control-Allow-Origin: *\r\n");
    try stream.writeAll("\r\n");

    // CAPA 3+4 — Enviar a Ollama con retry
    var attempt: u8 = 0;
    while (attempt < audio.MAX_RETRIES) : (attempt += 1) {
        if (attempt > 0) {
            std.log.warn("🔄 Retry {d}/{d}", .{ attempt, audio.MAX_RETRIES });
            if (!audio.waitForOllama(OLLAMA_BASE, allocator)) {
                std.Thread.sleep(audio.RETRY_DELAY_MS * std.time.ns_per_ms);
            }
            std.Thread.sleep(audio.RETRY_DELAY_MS * std.time.ns_per_ms);
        }

        const ok = proxyAudioToOllama(stream, ollama_body, allocator) catch false;
        if (ok) {
            std.log.info("✅ Audio OK en intento {d}", .{attempt + 1});
            try writeChunkEnd(stream);
            return;
        }
        std.log.warn("⚠️  Intento {d} falló", .{attempt + 1});
    }

    writeChunk(stream, "{\"error\":\"Max retries exceeded\",\"done\":true}\n") catch {};
    try writeChunkEnd(stream);
}

fn proxyAudioToOllama(
    stream: std.net.Stream,
    ollama_body: []const u8,
    allocator: std.mem.Allocator,
) !bool {
    const url = try std.fmt.allocPrint(allocator, "{s}/api/chat", .{OLLAMA_BASE});
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = client.request(.POST, uri, .{
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    }) catch return false;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = ollama_body.len };
    var bw = req.sendBodyUnflushed(&.{}) catch return false;
    bw.writer.writeAll(ollama_body) catch return false;
    bw.end() catch return false;
    req.connection.?.flush() catch return false;

    var redirect_buf: [1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return false;
    if (response.head.status != .ok) return false;

    var transfer_buf: [4096]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    var out_buf: [4096]u8 = undefined;
    while (true) {
        const n = body_reader.readSliceShort(&out_buf) catch return false;
        if (n == 0) break;
        writeChunk(stream, out_buf[0..n]) catch return false;
    }
    return true;
}

// ─── Servir archivos estáticos ────────────────────────────────────────────────

fn serveFile(stream: std.net.Stream, path: []const u8, allocator: std.mem.Allocator) !void {
    const content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch {
        return sendError(stream, 404, "File not found");
    };

    const mime = mimeType(path);

    var header_buf: [256]u8 = undefined;
    const headers = try std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-cache\r\n\r\n",
        .{ mime, content.len },
    );
    try stream.writeAll(headers);
    try stream.writeAll(content);
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    return "application/octet-stream";
}

// ─── Helpers HTTP ─────────────────────────────────────────────────────────────

fn sendJson(stream: std.net.Stream, status: u16, body: []const u8) !void {
    var buf: [512]u8 = undefined;
    const headers = try std.fmt.bufPrint(&buf,
        "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
        .{ status, body.len },
    );
    try stream.writeAll(headers);
    try stream.writeAll(body);
}

fn sendError(stream: std.net.Stream, status: u16, msg: []const u8) !void {
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"error\":\"{s}\"}}", .{msg});
    try sendJson(stream, status, body);
}

fn writeChunk(stream: std.net.Stream, data: []const u8) !void {
    var size_buf: [32]u8 = undefined;
    const size_str = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len});
    try stream.writeAll(size_str);
    try stream.writeAll(data);
    try stream.writeAll("\r\n");
}

fn writeChunkEnd(stream: std.net.Stream) !void {
    try stream.writeAll("0\r\n\r\n");
}

// ─── JSON field extractor minimalista ────────────────────────────────────────
// Extrae el valor de un campo string en JSON sin parsear todo el documento.
// Solo funciona para strings simples (no anidados).
pub fn jsonField(json: []const u8, field: []const u8) ?[]const u8 {
    const key = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{field}) catch return null;
    defer std.heap.page_allocator.free(key);

    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = std.mem.trimLeft(u8, json[pos + key.len ..], " \t\r\n");
    if (after_key.len == 0 or after_key[0] != '"') return null;
    const value_start = 1;
    var i: usize = value_start;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\') { i += 1; continue; }
        if (after_key[i] == '"') return after_key[value_start..i];
    }
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const audio_tests = @import("audio.zig"); // pulls audio.zig tests into this test binary

test "jsonField - basic extraction" {
    const json =
        \\{"model":"gemma4:e4b","text":"hello world"}
    ;
    try std.testing.expectEqualStrings("gemma4:e4b", jsonField(json, "model").?);
    try std.testing.expectEqualStrings("hello world", jsonField(json, "text").?);
}

test "jsonField - missing field returns null" {
    const json = "{\"model\":\"gemma4:e4b\"}";
    try std.testing.expect(jsonField(json, "audio") == null);
}

test "jsonField - empty json returns null" {
    try std.testing.expect(jsonField("{}", "model") == null);
}

test "jsonField - value with escaped quote" {
    const json =
        \\{"text":"say \"hi\""}
    ;
    try std.testing.expectEqualStrings("say \\\"hi\\\"", jsonField(json, "text").?);
}

test "jsonField - whitespace around colon" {
    const json =
        \\{"key":   "value"}
    ;
    try std.testing.expectEqualStrings("value", jsonField(json, "key").?);
}

test "mimeType - html" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeType("index.html"));
}

test "mimeType - javascript" {
    try std.testing.expectEqualStrings("application/javascript", mimeType("app.js"));
}

test "mimeType - png" {
    try std.testing.expectEqualStrings("image/png", mimeType("logo.png"));
}

test "mimeType - unknown extension falls back to octet-stream" {
    try std.testing.expectEqualStrings("application/octet-stream", mimeType("binary.bin"));
}
