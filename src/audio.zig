//! audio.zig — Pipeline de audio para Gemma4Visualizer
//!
//! CAPA 1 — ffmpeg:   bytes de audio → WAV mono 16kHz (con header RIFF)
//! CAPA 2 — Ollama:   WAV base64 en campo "images" → gemma4:e4b procesa audio
//!
//! La clave: Ollama detecta audio por el magic bytes RIFF/WAVE en el header.
//! Si se envía PCM raw (sin header), lo intenta decodificar como imagen y falla.

const std = @import("std");

pub const MAX_SECONDS: u32 = 30;
pub const MAX_RETRIES: u8 = 3;
pub const RETRY_DELAY_MS: u64 = 2_000;
pub const KEEP_ALIVE: []const u8 = "5m";

pub const AudioError = error{
    FfmpegNotFound,
    FfmpegFailed,
    EmptyAudio,
};

/// Verifica que ffmpeg esté disponible en el PATH.
pub fn verifyFfmpeg(allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(&.{ "ffmpeg", "-version" }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return AudioError.FfmpegNotFound,
        else => return AudioError.FfmpegNotFound,
    }
}

/// CAPA 1: Convierte audio crudo a WAV mono 16kHz usando ffmpeg.
/// Retorna los bytes del WAV (con header RIFF). El caller libera la memoria.
/// El WAV en base64 se envía a Ollama en el campo "images".
pub fn normalizeAudio(input_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (input_bytes.len == 0) return AudioError.EmptyAudio;

    const ts = std.time.milliTimestamp();
    const input_path = try std.fmt.allocPrint(allocator, "/tmp/g4v_in_{d}", .{ts});
    defer allocator.free(input_path);
    const wav_path = try std.fmt.allocPrint(allocator, "/tmp/g4v_{d}.wav", .{ts});
    defer allocator.free(wav_path);

    // Escribir bytes crudos del audio al disco
    {
        const f = try std.fs.createFileAbsolute(input_path, .{});
        defer f.close();
        try f.writeAll(input_bytes);
    }
    defer std.fs.deleteFileAbsolute(input_path) catch {};
    defer std.fs.deleteFileAbsolute(wav_path) catch {};

    const max_s = try std.fmt.allocPrint(allocator, "{d}", .{MAX_SECONDS});
    defer allocator.free(max_s);

    // Convertir a WAV mono 16kHz (el header RIFF es lo que Ollama detecta como audio)
    const argv = [_][]const u8{
        "ffmpeg", "-y",
        "-i",  input_path,
        "-ac", "1",      // mono
        "-ar", "16000",  // 16 kHz
        "-t",  max_s,    // máx 30s
        wav_path,        // ffmpeg infiere formato WAV por la extensión
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return AudioError.FfmpegFailed,
        else => return AudioError.FfmpegFailed,
    }

    // Leer el WAV y retornar sus bytes
    const f = try std.fs.openFileAbsolute(wav_path, .{});
    defer f.close();
    return try f.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

/// Codifica bytes a base64.
pub fn toBase64(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(data.len));
    _ = encoder.encode(out, data);
    return out;
}

/// Construye el JSON para Ollama con el WAV base64 en el campo "images".
/// Ollama v0.20+ detecta el header RIFF y lo procesa como audio en gemma4.
pub fn buildOllamaAudioRequest(
    model: []const u8,
    text: []const u8,
    wav_b64: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    // Escapar el texto del usuario para JSON
    var safe: std.ArrayList(u8) = .{};
    defer safe.deinit(allocator);
    for (text) |c| switch (c) {
        '"'  => try safe.appendSlice(allocator, "\\\""),
        '\\' => try safe.appendSlice(allocator, "\\\\"),
        '\n' => try safe.appendSlice(allocator, "\\n"),
        '\r' => {},
        else => try safe.append(allocator, c),
    };

    return std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","messages":[{{"role":"user","images":["{s}"],"content":"{s}"}}],"options":{{"num_ctx":8192}},"stream":true,"keep_alive":"{s}"}}
    , .{ model, wav_b64, safe.items, KEEP_ALIVE });
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "toBase64 - known vector" {
    const result = try toBase64("Hello", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("SGVsbG8=", result);
}

test "toBase64 - empty input" {
    const result = try toBase64("", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "toBase64 - binary bytes round-trip" {
    const input = [_]u8{ 0x00, 0xFF, 0x80, 0x7F };
    const encoded = try toBase64(&input, std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    const decoder = std.base64.standard.Decoder;
    const decoded = try std.testing.allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    defer std.testing.allocator.free(decoded);
    try decoder.decode(decoded, encoded);
    try std.testing.expectEqualSlices(u8, &input, decoded);
}

test "buildOllamaAudioRequest - contains required JSON fields" {
    const body = try buildOllamaAudioRequest("gemma4:e4b", "test prompt", "abc123==", std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gemma4:e4b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"images\":[\"abc123==\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"test prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"keep_alive\"") != null);
}

test "buildOllamaAudioRequest - escapes double quotes in text" {
    const body = try buildOllamaAudioRequest("gemma4:e4b", "say \"hi\"", "x", std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "say \\\"hi\\\"") != null);
}

test "buildOllamaAudioRequest - escapes backslashes in text" {
    const body = try buildOllamaAudioRequest("gemma4:e4b", "path\\to\\file", "x", std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "path\\\\to\\\\file") != null);
}

test "buildOllamaAudioRequest - strips carriage returns" {
    const body = try buildOllamaAudioRequest("gemma4:e4b", "line1\r\nline2", "x", std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\r") == null);
}

/// Verifica que Ollama esté respondiendo (health check).
pub fn waitForOllama(ollama_base: []const u8, allocator: std.mem.Allocator) bool {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const url = std.fmt.allocPrint(allocator, "{s}/api/tags", .{ollama_base}) catch return false;
    defer allocator.free(url);
    const result = client.fetch(.{ .location = .{ .url = url } }) catch return false;
    return result.status == .ok;
}
