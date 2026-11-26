// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The zigulee language server: diagnostics, hover, go to definition, find
//! references, rename, formatting, completion and document symbols for
//! `.zge` files, over the Language Server Protocol.
//!
//! Each open document is analyzed as a main file when it changes (its
//! imports are read from open documents or the disk). Hover, definition,
//! references and rename use the symbol index of the last analysis that
//! parsed; completion works on the text around the cursor plus that index,
//! so it keeps working while the code is incomplete.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const interp = @import("zigulee-interpreter");
const compiler = interp.compiler;
const Index = compiler.Index;
const Span = compiler.ast.Span;
const lexer = compiler.lexer;
const types = compiler.types;
const preview_mod = @import("preview.zig");
const core = @import("zigulee").core;
const log = std.log.scoped(.zigulee_lsp);
const Preview = preview_mod.Preview;

/// How LSP positions count characters.
pub const Encoding = enum { utf8, utf16 };

const Document = struct {
    uri: []u8,
    path: []u8,
    text: []u8,
    /// The last analysis in which the document parsed.
    analysis: ?*Analysis = null,

    fn deinit(d: *Document, gpa: Allocator) void {
        if (d.analysis) |a| a.destroy(gpa);
        gpa.free(d.uri);
        gpa.free(d.path);
        gpa.free(d.text);
    }
};

const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    index: Index,
    files: []const compiler.File,
    /// Absolute path of each file (for the built-in widgets, their copy in
    /// the cache directory, if there is one).
    paths: []const ?[]const u8,
    /// Whether each file is the user's (not a built-in widget).
    editable: []const bool,

    fn destroy(a: *Analysis, gpa: Allocator) void {
        a.arena.deinit();
        gpa.destroy(a);
    }
};

pub const Server = struct {
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    documents: std.StringHashMapUnmanaged(*Document) = .empty,
    encoding: Encoding = .utf16,
    shutdown_requested: bool = false,
    /// Set by `exit`: the process should end with `exitCode()`.
    exited: bool = false,
    style: []const u8 = compiler.std_widgets.default_style,
    /// The live preview, if the editor opened one.
    preview: ?*Preview = null,
    preview_files: ?*Files = null,
    /// Where the built-in widgets' sources are written, so editors can
    /// open them (go to definition). Null: they are not shown.
    std_dir: ?[]const u8 = null,
    std_written: bool = false,
    /// The workspace folders (for rename and references across files).
    roots: std.ArrayList([]u8) = .empty,

    pub fn init(gpa: Allocator, io: std.Io, out: *std.Io.Writer) Server {
        return .{ .gpa = gpa, .io = io, .out = out };
    }

    pub fn deinit(s: *Server) void {
        s.closePreview();
        for (s.roots.items) |r| s.gpa.free(r);
        s.roots.deinit(s.gpa);
        var it = s.documents.valueIterator();
        while (it.next()) |d| {
            d.*.deinit(s.gpa);
            s.gpa.destroy(d.*);
        }
        s.documents.deinit(s.gpa);
    }

    pub fn exitCode(s: *const Server) u8 {
        return if (s.shutdown_requested) 0 else 1;
    }

    // ---- Transport ----

    /// Reads one message (`Content-Length` header and body) from `in`.
    /// Returns null at the end of the input.
    pub fn readMessage(gpa: Allocator, in: *std.Io.Reader) !?[]u8 {
        var length: ?usize = null;
        while (true) {
            const raw = in.takeDelimiterExclusive('\n') catch |err| switch (err) {
                error.EndOfStream => return null,
                else => |e| return e,
            };
            in.toss(1); // the newline
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(line, "content-length:"))
                length = std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " "), 10) catch return error.InvalidHeader;
        }
        return try in.readAlloc(gpa, length orelse return error.InvalidHeader);
    }

    fn send(s: *Server, body: []const u8) !void {
        try s.out.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try s.out.writeAll(body);
        try s.out.flush();
    }

    /// A JSON message being written.
    const Message = struct {
        aw: std.Io.Writer.Allocating,
        js: json.Stringify,

        fn init(m: *Message, gpa: Allocator) void {
            m.aw = .init(gpa);
            m.js = .{ .writer = &m.aw.writer };
        }

        fn deinit(m: *Message) void {
            m.aw.deinit();
        }

        /// `{"jsonrpc":"2.0","id":id,"result":` (the caller writes the result).
        fn response(m: *Message, id: json.Value) !void {
            try m.js.beginObject();
            try m.js.objectField("jsonrpc");
            try m.js.write("2.0");
            try m.js.objectField("id");
            try m.js.write(id);
            try m.js.objectField("result");
        }

        fn notification(m: *Message, method: []const u8) !void {
            try m.js.beginObject();
            try m.js.objectField("jsonrpc");
            try m.js.write("2.0");
            try m.js.objectField("method");
            try m.js.write(method);
            try m.js.objectField("params");
        }
    };

    fn finish(s: *Server, m: *Message) !void {
        try m.js.endObject();
        try s.send(m.aw.written());
    }

    fn respondNull(s: *Server, id: json.Value) !void {
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.write(null);
        try s.finish(&m);
    }

    fn respondError(s: *Server, id: json.Value, code: i32, message: []const u8) !void {
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.js.beginObject();
        try m.js.objectField("jsonrpc");
        try m.js.write("2.0");
        try m.js.objectField("id");
        try m.js.write(id);
        try m.js.objectField("error");
        try m.js.beginObject();
        try m.js.objectField("code");
        try m.js.write(code);
        try m.js.objectField("message");
        try m.js.write(message);
        try m.js.endObject();
        try s.finish(&m);
    }

    // ---- Dispatch ----

    /// Handles one JSON-RPC message.
    pub fn handle(s: *Server, body: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const msg = json.parseFromSliceLeaky(json.Value, arena.allocator(), body, .{}) catch return;
        if (msg != .object) return;
        const method = getString(msg, "method") orelse return; // a response to us: ignored
        const params = msg.object.get("params") orelse .null;
        const id = msg.object.get("id");
        const a = arena.allocator();

        if (id) |req| {
            if (s.shutdown_requested and !std.mem.eql(u8, method, "exit")) return s.respondError(req, -32600, "the server is shutting down");
            if (std.mem.eql(u8, method, "initialize")) return s.initialize(req, params);
            if (std.mem.eql(u8, method, "shutdown")) {
                s.shutdown_requested = true;
                return s.respondNull(req);
            }
            if (std.mem.eql(u8, method, "textDocument/hover")) return s.hover(a, req, params);
            if (std.mem.eql(u8, method, "textDocument/definition")) return s.definition(a, req, params);
            if (std.mem.eql(u8, method, "textDocument/references")) return s.references(a, req, params);
            if (std.mem.eql(u8, method, "textDocument/prepareRename")) return s.prepareRename(a, req, params);
            if (std.mem.eql(u8, method, "textDocument/rename")) return s.rename(a, req, params);
            if (std.mem.eql(u8, method, "textDocument/formatting")) return s.formatting(req, params);
            if (std.mem.eql(u8, method, "textDocument/completion")) return s.completion(a, req, params);
            if (std.mem.eql(u8, method, "textDocument/documentSymbol")) return s.documentSymbols(a, req, params);
            if (std.mem.eql(u8, method, "zigulee/preview")) return s.startPreview(a, req, params);
            if (std.mem.eql(u8, method, "zigulee/previewInspect")) return s.previewInspect(a, req, params);
            if (std.mem.eql(u8, method, "zigulee/previewSetProperty")) return s.previewSetProperty(a, req, params);
            return s.respondError(req, -32601, "method not supported");
        }
        if (std.mem.eql(u8, method, "exit")) {
            s.exited = true;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            const td = getObject(params, "textDocument") orelse return;
            try s.setDocument(getString(td, "uri") orelse return, getString(td, "text") orelse return);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            const uri = getString(getObject(params, "textDocument") orelse return, "uri") orelse return;
            const changes = getArray(params, "contentChanges") orelse return;
            if (changes.len == 0) return;
            // Full synchronization: the last change has the whole text.
            try s.setDocument(uri, getString(changes[changes.len - 1], "text") orelse return);
        } else if (std.mem.eql(u8, method, "zigulee/previewInput")) {
            try s.previewInput(a, params);
        } else if (std.mem.eql(u8, method, "zigulee/previewSelect")) {
            try s.previewSelect(a, params);
        } else if (std.mem.eql(u8, method, "zigulee/previewClose")) {
            s.closePreview();
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            const uri = getString(getObject(params, "textDocument") orelse return, "uri") orelse return;
            if (s.documents.fetchRemove(uri)) |kv| {
                kv.value.deinit(s.gpa);
                s.gpa.destroy(kv.value);
            }
        }
    }

    fn initialize(s: *Server, id: json.Value, params: json.Value) !void {
        // UTF-8 positions if the client supports them.
        if (getObject(params, "capabilities")) |caps| if (getObject(caps, "general")) |general| if (getArray(general, "positionEncodings")) |encs| {
            for (encs) |e| if (e == .string and std.mem.eql(u8, e.string, "utf-8")) {
                s.encoding = .utf8;
            };
        };
        if (getObject(params, "initializationOptions")) |opts| if (getString(opts, "style")) |style| {
            if (compiler.std_widgets.isStyle(style)) s.style = style;
        };
        // Workspace folders, else the root.
        if (getArray(params, "workspaceFolders")) |folders| {
            for (folders) |f| if (getString(f, "uri")) |uri| try s.roots.append(s.gpa, try uriToPath(s.gpa, uri));
        } else if (getString(params, "rootUri")) |uri| {
            try s.roots.append(s.gpa, try uriToPath(s.gpa, uri));
        }
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.write(.{
            .capabilities = .{
                .positionEncoding = if (s.encoding == .utf8) "utf-8" else "utf-16",
                .textDocumentSync = 1, // full
                .hoverProvider = true,
                .definitionProvider = true,
                .referencesProvider = true,
                .renameProvider = .{ .prepareProvider = true },
                .documentFormattingProvider = true,
                .documentSymbolProvider = true,
                .completionProvider = .{ .triggerCharacters = .{"."} },
                .experimental = .{ .ziguleePreview = true },
            },
            .serverInfo = .{ .name = "zigulee-lsp", .version = "0.1.0" },
        });
        try s.finish(&m);
    }

    // ---- Documents and analysis ----

    fn setDocument(s: *Server, uri: []const u8, text: []const u8) !void {
        const gop = try s.documents.getOrPut(s.gpa, uri);
        if (!gop.found_existing) {
            const doc = try s.gpa.create(Document);
            doc.* = .{ .uri = try s.gpa.dupe(u8, uri), .path = try uriToPath(s.gpa, uri), .text = try s.gpa.dupe(u8, text) };
            gop.key_ptr.* = doc.uri;
            gop.value_ptr.* = doc;
        } else {
            const doc = gop.value_ptr.*;
            s.gpa.free(doc.text);
            doc.text = try s.gpa.dupe(u8, text);
        }
        try s.analyzeDocument(gop.value_ptr.*);
        if (s.preview != null) try s.reloadPreview();
    }

    const Files = struct {
        server: *Server,
        dir: []const u8,

        fn read(ctx: ?*anyopaque, arena: Allocator, path: []const u8) anyerror![]const u8 {
            const self: *Files = @ptrCast(@alignCast(ctx.?));
            const full = try std.fs.path.resolve(arena, &.{ self.dir, path });
            // Open documents win over the disk.
            var it = self.server.documents.valueIterator();
            while (it.next()) |d| if (std.mem.eql(u8, d.*.path, full)) return arena.dupe(u8, d.*.text);
            return std.Io.Dir.cwd().readFileAlloc(self.server.io, full, arena, .limited(16 << 20));
        }
    };

    /// Analyzes `text` as the file at `path` (imports read from open
    /// documents or the disk).
    fn analyzeText(s: *Server, path: []const u8, text: []const u8) !struct { analysis: *Analysis, result: compiler.Analysis } {
        const analysis = try s.gpa.create(Analysis);
        analysis.* = .{ .arena = .init(s.gpa), .index = undefined, .files = &.{}, .paths = &.{}, .editable = &.{} };
        errdefer analysis.destroy(s.gpa);
        const a = analysis.arena.allocator();
        analysis.index = .{ .arena = a };
        const dir = std.fs.path.dirname(path) orelse ".";
        var files: Files = .{ .server = s, .dir = dir };
        // The index points into the source: the analysis keeps its own copy.
        const result = try compiler.analyze(a, try a.dupe(u8, path), try a.dupe(u8, text), .{
            .loader = .{ .ctx = &files, .readFn = Files.read },
            .style = s.style,
            .index = &analysis.index,
        });
        analysis.files = result.files;
        const paths = try a.alloc(?[]const u8, result.files.len);
        const editable = try a.alloc(bool, result.files.len);
        for (result.files, paths, editable, 0..) |f, *p, *e, i| {
            const builtin = compiler.std_widgets.isStd(f.name);
            e.* = !builtin;
            p.* = if (i == 0) f.name else if (builtin) s.stdPath(a, f.name) else try std.fs.path.resolve(a, &.{ dir, f.name });
        }
        analysis.paths = paths;
        analysis.editable = editable;
        return .{ .analysis = analysis, .result = result };
    }

    fn analyzeDocument(s: *Server, doc: *Document) !void {
        const done = try s.analyzeText(doc.path, doc.text);
        const analysis = done.analysis;
        const result = done.result;
        var keep = false;
        defer if (!keep) analysis.destroy(s.gpa);
        const a = analysis.arena.allocator();

        // Diagnostics for this document and the files it imports.
        for (result.files, 0..) |f, i| {
            if (!analysis.editable[i]) continue;
            const path = analysis.paths[i] orelse continue;
            var has = false;
            for (result.diagnostics) |d| has = has or d.file == i;
            if (!has and i != 0) continue;
            try s.publishDiagnostics(a, if (i == 0) doc.uri else try pathToUri(a, path), f.source, result.diagnostics, @intCast(i));
        }
        if (result.parsed) {
            if (doc.analysis) |old| old.destroy(s.gpa);
            doc.analysis = analysis;
            keep = true;
        }
    }

    /// The path of a built-in widget file's copy (writing the copies first).
    fn stdPath(s: *Server, a: Allocator, name: []const u8) ?[]const u8 {
        const dir = s.std_dir orelse return null;
        if (!s.std_written) {
            s.writeStdFiles(a, dir) catch |err| {
                log.err("cannot write the standard widgets to {s}: {t}", .{ dir, err });
                return null;
            };
            s.std_written = true;
        }
        return std.fs.path.join(a, &.{ dir, s.style, name["@std/".len..] }) catch null;
    }

    /// Writes the built-in widget files of the style (unchanged ones are
    /// left alone).
    fn writeStdFiles(s: *Server, a: Allocator, dir: []const u8) !void {
        const style_dir = try std.fs.path.join(a, &.{ dir, s.style });
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(s.io, style_dir);
        for (compiler.std_widgets.fileNames()) |name| {
            const source = compiler.std_widgets.read(s.style, try std.fmt.allocPrint(a, "@std/{s}", .{name})) orelse continue;
            const path = try std.fs.path.join(a, &.{ style_dir, name });
            if (cwd.readFileAlloc(s.io, path, a, .limited(1 << 20))) |existing| {
                if (std.mem.eql(u8, existing, source)) continue;
            } else |_| {}
            try cwd.writeFile(s.io, .{ .sub_path = path, .data = source });
        }
    }

    fn publishDiagnostics(s: *Server, a: Allocator, uri: []const u8, text: []const u8, diags: []const compiler.Diagnostic, file: u16) !void {
        _ = a;
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.notification("textDocument/publishDiagnostics");
        try m.js.beginObject();
        try m.js.objectField("uri");
        try m.js.write(uri);
        try m.js.objectField("diagnostics");
        try m.js.beginArray();
        for (diags) |d| if (d.file == file) {
            try m.js.beginObject();
            try m.js.objectField("range");
            try s.writeRange(&m.js, text, d.span);
            try m.js.objectField("severity");
            try m.js.write(1);
            try m.js.objectField("source");
            try m.js.write("zgec");
            try m.js.objectField("message");
            try m.js.write(d.message);
            try m.js.endObject();
        };
        try m.js.endArray();
        try m.js.endObject();
        try s.finish(&m);
    }

    // ---- Positions ----

    pub const Position = struct { line: u32, character: u32 };

    pub fn positionOf(enc: Encoding, text: []const u8, offset: u32) Position {
        var line: u32 = 0;
        var line_start: usize = 0;
        const end = @min(offset, text.len);
        for (text[0..end], 0..) |ch, i| if (ch == '\n') {
            line += 1;
            line_start = i + 1;
        };
        const prefix = text[line_start..end];
        const character: usize = switch (enc) {
            .utf8 => prefix.len,
            .utf16 => utf16Length(prefix),
        };
        return .{ .line = line, .character = @intCast(character) };
    }

    pub fn offsetOf(enc: Encoding, text: []const u8, pos: Position) u32 {
        var line: u32 = 0;
        var i: usize = 0;
        while (line < pos.line and i < text.len) : (i += 1) {
            if (text[i] == '\n') line += 1;
        }
        const line_end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        switch (enc) {
            .utf8 => return @intCast(@min(i + pos.character, line_end)),
            .utf16 => {
                var units: u32 = 0;
                while (i < line_end and units < pos.character) {
                    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                    units += if (n == 4) 2 else 1;
                    i += @min(n, line_end - i);
                }
                return @intCast(i);
            },
        }
    }

    fn utf16Length(s: []const u8) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            n += if (len == 4) 2 else 1;
            i += len;
        }
        return n;
    }

    fn writePosition(s: *Server, js: *json.Stringify, text: []const u8, offset: u32) json.Stringify.Error!void {
        const p = positionOf(s.encoding, text, offset);
        try js.write(.{ .line = p.line, .character = p.character });
    }

    fn writeRange(s: *Server, js: *json.Stringify, text: []const u8, span: Span) json.Stringify.Error!void {
        try js.beginObject();
        try js.objectField("start");
        try s.writePosition(js, text, span.start);
        try js.objectField("end");
        try s.writePosition(js, text, span.end);
        try js.endObject();
    }

    /// The document and cursor offset of a `TextDocumentPositionParams`.
    fn at(s: *Server, params: json.Value) ?struct { doc: *Document, offset: u32 } {
        const uri = getString(getObject(params, "textDocument") orelse return null, "uri") orelse return null;
        const doc = s.documents.get(uri) orelse return null;
        const pos = getObject(params, "position") orelse return null;
        const line = getInt(pos, "line") orelse return null;
        const character = getInt(pos, "character") orelse return null;
        return .{ .doc = doc, .offset = offsetOf(s.encoding, doc.text, .{ .line = @intCast(line), .character = @intCast(character) }) };
    }

    /// The symbol referenced at the cursor.
    fn symbolAt(s: *Server, params: json.Value) ?struct { doc: *Document, analysis: *Analysis, ref: compiler.index.Reference } {
        const p = s.at(params) orelse return null;
        const analysis = p.doc.analysis orelse return null;
        const ref = analysis.index.referenceAt(0, p.offset) orelse return null;
        return .{ .doc = p.doc, .analysis = analysis, .ref = ref };
    }

    // ---- Requests ----

    fn hover(s: *Server, a: Allocator, id: json.Value, params: json.Value) !void {
        const found = s.symbolAt(params) orelse return s.respondNull(id);
        const sym = found.analysis.index.symbols.items[found.ref.symbol];
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.beginObject();
        try m.js.objectField("contents");
        try m.js.write(.{ .kind = "markdown", .value = try std.fmt.allocPrint(a, "```zge\n{s}\n```", .{sym.detail}) });
        try m.js.objectField("range");
        try s.writeRange(&m.js, found.doc.text, found.ref.loc.span);
        try m.js.endObject();
        try s.finish(&m);
    }

    fn writeLocation(s: *Server, a: Allocator, js: *json.Stringify, analysis: *Analysis, doc: *Document, loc: compiler.index.Location) !bool {
        const path = analysis.paths[loc.file] orelse return false;
        try js.beginObject();
        try js.objectField("uri");
        try js.write(if (loc.file == 0) doc.uri else try s.uriFor(a, path));
        try js.objectField("range");
        try s.writeRange(js, analysis.files[loc.file].source, loc.span);
        try js.endObject();
        return true;
    }

    /// The URI of a file: an open document's own, else one made from the path.
    fn uriFor(s: *Server, a: Allocator, path: []const u8) ![]const u8 {
        var it = s.documents.valueIterator();
        while (it.next()) |d| if (std.mem.eql(u8, d.*.path, path)) return d.*.uri;
        return pathToUri(a, path);
    }

    fn definition(s: *Server, a: Allocator, id: json.Value, params: json.Value) !void {
        const found = s.symbolAt(params) orelse return s.respondNull(id);
        const decl = found.analysis.index.symbols.items[found.ref.symbol].decl orelse return s.respondNull(id);
        if (found.analysis.paths[decl.file] == null) return s.respondNull(id);
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        _ = try s.writeLocation(a, &m.js, found.analysis, found.doc, decl);
        try s.finish(&m);
    }

    /// A symbol across analyses: where it is declared.
    const SymbolKey = struct { path: []const u8, start: u32 };

    fn keyOf(analysis: *const Analysis, sym: u32) ?SymbolKey {
        const decl = analysis.index.symbols.items[sym].decl orelse return null;
        if (!analysis.editable[decl.file]) return null;
        const path = analysis.paths[decl.file] orelse return null;
        return .{ .path = path, .start = decl.span.start };
    }

    /// A reference found in the workspace.
    const FoundRef = struct { path: []const u8, source: []const u8, span: Span, is_decl: bool };

    /// The `.zge` files in the workspace folders (not in build or hidden
    /// directories).
    fn workspaceFiles(s: *Server, a: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (s.roots.items) |root| {
            var dir = std.Io.Dir.cwd().openDir(s.io, root, .{ .iterate = true }) catch continue;
            defer dir.close(s.io);
            var walker = try dir.walkSelectively(s.gpa);
            defer walker.deinit();
            while (walker.next(s.io) catch null) |entry| {
                const base = entry.basename;
                switch (entry.kind) {
                    .directory => {
                        const skip = base.len == 0 or base[0] == '.' or std.mem.eql(u8, base, "zig-out") or
                            std.mem.eql(u8, base, "zig-pkg") or std.mem.eql(u8, base, "node_modules");
                        if (!skip) walker.enter(s.io, entry) catch {};
                    },
                    .file => if (std.mem.endsWith(u8, base, ".zge")) try out.append(a, try std.fs.path.join(a, &.{ root, entry.path })),
                    else => {},
                }
            }
        }
        return out.items;
    }

    /// Every reference to the symbol declared at `key`, in the open
    /// documents and the workspace's files (and the files they import).
    fn referencesEverywhere(s: *Server, a: Allocator, current: *Analysis, key: SymbolKey) ![]FoundRef {
        var out: std.ArrayList(FoundRef) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var done: std.StringHashMapUnmanaged(void) = .empty;
        try s.collectFrom(a, current, key, &out, &seen);
        try done.put(a, current.files[0].name, {});
        var it = s.documents.valueIterator();
        while (it.next()) |d| {
            const an = d.*.analysis orelse continue;
            if ((try done.getOrPut(a, d.*.path)).found_existing) continue;
            try s.collectFrom(a, an, key, &out, &seen);
        }
        for (try s.workspaceFiles(a)) |path| {
            if ((try done.getOrPut(a, path)).found_existing) continue;
            const text = std.Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(16 << 20)) catch continue;
            const fresh = s.analyzeText(path, text) catch continue;
            defer fresh.analysis.destroy(s.gpa);
            // The references point into the analysis: copy what is kept.
            var before = out.items.len;
            try s.collectFrom(a, fresh.analysis, key, &out, &seen);
            while (before < out.items.len) : (before += 1) {
                out.items[before].path = try a.dupe(u8, out.items[before].path);
                out.items[before].source = try a.dupe(u8, out.items[before].source);
            }
        }
        return out.items;
    }

    fn collectFrom(s: *Server, a: Allocator, analysis: *Analysis, key: SymbolKey, out: *std.ArrayList(FoundRef), seen: *std.StringHashMapUnmanaged(void)) !void {
        _ = s;
        const ix = &analysis.index;
        for (ix.symbols.items, 0..) |_, i| {
            const k = keyOf(analysis, @intCast(i)) orelse continue;
            if (k.start != key.start or !std.mem.eql(u8, k.path, key.path)) continue;
            for (ix.references.items) |r| {
                if (r.symbol != i or !analysis.editable[r.loc.file]) continue;
                const path = analysis.paths[r.loc.file] orelse continue;
                const id = try std.fmt.allocPrint(a, "{s}:{d}", .{ path, r.loc.span.start });
                if ((try seen.getOrPut(a, id)).found_existing) continue;
                try out.append(a, .{
                    .path = path,
                    .source = analysis.files[r.loc.file].source,
                    .span = r.loc.span,
                    .is_decl = r.loc.span.start == key.start and std.mem.eql(u8, path, key.path),
                });
            }
        }
    }

    fn references(s: *Server, a: Allocator, id: json.Value, params: json.Value) !void {
        const found = s.symbolAt(params) orelse return s.respondNull(id);
        const include_decl = if (getObject(params, "context")) |ctx| (if (ctx.object.get("includeDeclaration")) |v| v == .bool and v.bool else false) else false;
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.beginArray();
        if (keyOf(found.analysis, found.ref.symbol)) |key| {
            for (try s.referencesEverywhere(a, found.analysis, key)) |r| {
                if (r.is_decl and !include_decl) continue;
                try m.js.beginObject();
                try m.js.objectField("uri");
                try m.js.write(try s.uriFor(a, r.path));
                try m.js.objectField("range");
                try s.writeRange(&m.js, r.source, r.span);
                try m.js.endObject();
            }
        } else {
            // Built-in names: their uses in this document and its imports.
            const ix = &found.analysis.index;
            for (try ix.referencesTo(a, found.ref.symbol)) |loc| {
                if (!found.analysis.editable[loc.file]) continue;
                _ = try s.writeLocation(a, &m.js, found.analysis, found.doc, loc);
            }
        }
        try m.js.endArray();
        try s.finish(&m);
    }

    /// Symbols the user declared in an editable file.
    fn renamable(found: anytype) bool {
        return keyOf(found.analysis, found.ref.symbol) != null;
    }

    fn prepareRename(s: *Server, a: Allocator, id: json.Value, params: json.Value) !void {
        _ = a;
        const found = s.symbolAt(params) orelse return s.respondNull(id);
        if (!renamable(found)) return s.respondNull(id);
        const sym = found.analysis.index.symbols.items[found.ref.symbol];
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.beginObject();
        try m.js.objectField("range");
        try s.writeRange(&m.js, found.doc.text, found.ref.loc.span);
        try m.js.objectField("placeholder");
        try m.js.write(sym.name);
        try m.js.endObject();
        try s.finish(&m);
    }

    fn rename(s: *Server, a: Allocator, id: json.Value, params: json.Value) !void {
        const found = s.symbolAt(params) orelse return s.respondNull(id);
        const key = keyOf(found.analysis, found.ref.symbol) orelse return s.respondError(id, -32602, "this name cannot be renamed");
        const new_name = getString(params, "newName") orelse return s.respondError(id, -32602, "missing newName");
        if (!isIdentifier(new_name)) return s.respondError(id, -32602, "not a valid name");
        const refs = try s.referencesEverywhere(a, found.analysis, key);
        // Edits grouped by file.
        var by_path: std.StringArrayHashMapUnmanaged(std.ArrayList(FoundRef)) = .empty;
        for (refs) |r| {
            const gop = try by_path.getOrPut(a, r.path);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, r);
        }
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.beginObject();
        try m.js.objectField("changes");
        try m.js.beginObject();
        var it = by_path.iterator();
        while (it.next()) |e| {
            try m.js.objectField(try s.uriFor(a, e.key_ptr.*));
            try m.js.beginArray();
            for (e.value_ptr.items) |r| {
                try m.js.beginObject();
                try m.js.objectField("range");
                try s.writeRange(&m.js, r.source, r.span);
                try m.js.objectField("newText");
                try m.js.write(new_name);
                try m.js.endObject();
            }
            try m.js.endArray();
        }
        try m.js.endObject();
        try m.js.endObject();
        try s.finish(&m);
    }

    fn formatting(s: *Server, id: json.Value, params: json.Value) !void {
        const uri = getString(getObject(params, "textDocument") orelse return s.respondNull(id), "uri") orelse return s.respondNull(id);
        const doc = s.documents.get(uri) orelse return s.respondNull(id);
        const formatted = compiler.format(s.gpa, doc.text) catch |err| switch (err) {
            error.InvalidSource => return s.respondNull(id),
            else => |e| return e,
        };
        defer s.gpa.free(formatted);
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.beginArray();
        if (!std.mem.eql(u8, formatted, doc.text)) {
            try m.js.beginObject();
            try m.js.objectField("range");
            try s.writeRange(&m.js, doc.text, .{ .start = 0, .end = @intCast(doc.text.len) });
            try m.js.objectField("newText");
            try m.js.write(formatted);
            try m.js.endObject();
        }
        try m.js.endArray();
        try s.finish(&m);
    }

    // ---- Document symbols ----

    fn documentSymbols(s: *Server, a: Allocator, id: json.Value, params: json.Value) !void {
        const uri = getString(getObject(params, "textDocument") orelse return s.respondNull(id), "uri") orelse return s.respondNull(id);
        const doc = s.documents.get(uri) orelse return s.respondNull(id);
        var diags: compiler.Diagnostics = .{ .arena = a };
        _ = try diags.addFile(doc.path, doc.text);
        var parser: compiler.Parser = .init(a, doc.text, &diags);
        const parsed = parser.parseDocument() catch |err| switch (err) {
            error.ParseError => null,
            else => |e| return e,
        };
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.beginArray();
        if (parsed) |d| {
            for (d.components) |*c| {
                const range = c.name.span.join(c.root.span);
                try s.beginSymbol(&m.js, doc.text, c.name.name, if (c.is_global) "global" else c.root.type_name.name, if (c.is_global) 2 else 5, range, c.name.span);
                try s.elementChildren(&m.js, doc.text, &c.root);
                try m.js.endArray();
                try m.js.endObject();
            }
            for (d.structs) |st| {
                try s.beginSymbol(&m.js, doc.text, st.name.name, "struct", 23, st.name.span, st.name.span);
                for (st.fields) |f| {
                    try s.beginSymbol(&m.js, doc.text, f.name.name, f.type_name.name.name, 8, f.name.span.join(f.type_name.span), f.name.span);
                    try m.js.endArray();
                    try m.js.endObject();
                }
                try m.js.endArray();
                try m.js.endObject();
            }
            for (d.enums) |e| {
                try s.beginSymbol(&m.js, doc.text, e.name.name, "enum", 10, e.name.span, e.name.span);
                for (e.values) |v| {
                    try s.beginSymbol(&m.js, doc.text, v.name, "", 22, v.span, v.span);
                    try m.js.endArray();
                    try m.js.endObject();
                }
                try m.js.endArray();
                try m.js.endObject();
            }
        }
        try m.js.endArray();
        try s.finish(&m);
    }

    /// Writes a DocumentSymbol up to its open `children` array.
    fn beginSymbol(s: *Server, js: *json.Stringify, text: []const u8, name: []const u8, detail: []const u8, kind: u8, range: Span, selection: Span) json.Stringify.Error!void {
        try js.beginObject();
        try js.objectField("name");
        try js.write(name);
        try js.objectField("detail");
        try js.write(detail);
        try js.objectField("kind");
        try js.write(kind);
        try js.objectField("range");
        try s.writeRange(js, text, range);
        try js.objectField("selectionRange");
        try s.writeRange(js, text, selection);
        try js.objectField("children");
        try js.beginArray();
    }

    fn elementChildren(s: *Server, js: *json.Stringify, text: []const u8, e: *const compiler.ast.Element) json.Stringify.Error!void {
        for (e.members) |m| switch (m) {
            .property => |p| {
                try s.beginSymbol(js, text, p.name.name, p.type_name.name.name, 7, p.span, p.name.span);
                try js.endArray();
                try js.endObject();
            },
            .callback => |cb| {
                try s.beginSymbol(js, text, cb.name.name, "callback", 24, cb.span, cb.name.span);
                try js.endArray();
                try js.endObject();
            },
            .child => |child| try s.elementSymbol(js, text, child),
            .repeated => |r| try s.elementSymbol(js, text, r.element),
            .conditional => |c| try s.elementSymbol(js, text, c.element),
            else => {},
        };
    }

    fn elementSymbol(s: *Server, js: *json.Stringify, text: []const u8, e: *const compiler.ast.Element) json.Stringify.Error!void {
        const name = if (e.id) |id| id.name else e.type_name.name;
        try s.beginSymbol(js, text, name, e.type_name.name, 19, e.span, if (e.id) |id| id.span else e.type_name.span);
        try s.elementChildren(js, text, e);
        try js.endArray();
        try js.endObject();
    }

    // ---- Live preview ----

    fn closePreview(s: *Server) void {
        if (s.preview) |p| p.destroy();
        if (s.preview_files) |f| s.gpa.destroy(f);
        s.preview = null;
        s.preview_files = null;
    }

    /// The text of the previewed file: the open document, else the disk.
    fn previewSource(s: *Server, a: Allocator, p: *Preview) ![]const u8 {
        var it = s.documents.valueIterator();
        while (it.next()) |d| if (std.mem.eql(u8, d.*.path, p.path)) return d.*.text;
        return std.Io.Dir.cwd().readFileAlloc(s.io, p.path, a, .limited(16 << 20));
    }

    fn startPreview(s: *Server, a: Allocator, id: json.Value, params: json.Value) !void {
        const uri = getString(params, "uri") orelse return s.respondError(id, -32602, "missing uri");
        const path = try uriToPath(a, uri);
        const same = if (s.preview) |p| std.mem.eql(u8, p.path, path) else false;
        if (!same) {
            s.closePreview();
            const files = try s.gpa.create(Files);
            files.* = .{ .server = s, .dir = std.fs.path.dirname(path) orelse "." };
            s.preview_files = files;
            // `files.dir` points into `path`, owned by the preview.
            s.preview = try Preview.create(s.gpa, s.io, .{ .ctx = files, .readFn = Files.read }, path, s.style);
            files.dir = std.fs.path.dirname(s.preview.?.path) orelse ".";
        }
        const p = s.preview.?;
        if (params.object.get("component")) |c| try p.setComponent(if (c == .string) c.string else null);
        if (params.object.get("scale")) |sc| switch (sc) {
            .float => |f| p.scale = std.math.clamp(@as(f32, @floatCast(f)), 0.25, 8),
            .integer => |n| p.scale = std.math.clamp(@as(f32, @floatFromInt(n)), 0.25, 8),
            else => {},
        };
        p.full = true;
        try p.load(try s.previewSource(a, p));
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.write(.{
            .components = try p.componentNames(a),
            .component = if (p.instance) |inst| inst.comp.name else "",
            .errors = p.errors,
        });
        try s.finish(&m);
        try s.sendFrame(a);
    }

    fn reloadPreview(s: *Server) !void {
        const p = s.preview orelse return;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const source = s.previewSource(arena.allocator(), p) catch |err| {
            log.err("preview: cannot read {s}: {t}", .{ p.path, err });
            return;
        };
        try p.load(source);
        try s.sendFrame(arena.allocator());
    }

    fn sendFrame(s: *Server, a: Allocator) !void {
        const p = s.preview orelse return;
        const frame = try p.frame(a);
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.notification("zigulee/previewFrame");
        try m.js.write(frame);
        try s.finish(&m);
    }

    fn previewInput(s: *Server, a: Allocator, params: json.Value) !void {
        const p = s.preview orelse return;
        const kind = getString(params, "type") orelse return;
        const x = getFloat(params, "x");
        const y = getFloat(params, "y");
        const button: core.input.PointerButton = switch (getInt(params, "button") orelse 0) {
            0 => .left,
            1 => .middle,
            2 => .right,
            else => .other,
        };
        const mods: core.input.Modifiers = .{
            .shift = getBool(params, "shift"),
            .control = getBool(params, "control"),
            .alt = getBool(params, "alt"),
            .meta = getBool(params, "meta"),
        };
        const input: ?preview_mod.Input = if (std.mem.eql(u8, kind, "press"))
            .{ .press = .{ .x = x, .y = y, .button = button, .modifiers = mods } }
        else if (std.mem.eql(u8, kind, "release"))
            .{ .release = .{ .x = x, .y = y, .button = button } }
        else if (std.mem.eql(u8, kind, "move"))
            .{ .move = .{ .x = x, .y = y } }
        else if (std.mem.eql(u8, kind, "wheel"))
            .{ .wheel = .{ .x = x, .y = y, .dx = getFloat(params, "dx"), .dy = getFloat(params, "dy") } }
        else if (std.mem.eql(u8, kind, "exit"))
            .exit
        else if (std.mem.eql(u8, kind, "key"))
            .{ .key = .{ .text = getString(params, "text") orelse return, .modifiers = mods, .released = getBool(params, "released") } }
        else if (std.mem.eql(u8, kind, "tick"))
            .tick
        else if (std.mem.eql(u8, kind, "scale")) blk: {
            const scale = getFloat(params, "scale");
            if (scale > 0) p.scale = std.math.clamp(scale, 0.25, 8);
            p.full = true;
            break :blk .tick;
        } else null;
        p.handleInput(input orelse return);
        try s.sendFrame(a);
    }

    /// Label, location and properties of the selected element.
    fn writeSelection(s: *Server, a: Allocator, js: *json.Stringify, p: *Preview) !void {
        try js.objectField("properties");
        try js.beginArray();
        if (p.selected) |sel| for (try interp.Inspect.properties(sel, a)) |prop| try js.write(.{
            .name = prop.name,
            .type = prop.type_name,
            .value = prop.value,
            .editable = prop.editable,
        });
        try js.endArray();
        try js.objectField("selected");
        if (p.selected) |sel| try s.writeElement(a, js, p, sel) else try js.write(null);
    }

    fn writeElement(s: *Server, a: Allocator, js: *json.Stringify, p: *Preview, el: interp.ElementRef) !void {
        try js.beginObject();
        try js.objectField("label");
        try js.write(if (el.id()) |i| try std.fmt.allocPrint(a, "{s} := {s}", .{ i, el.typeName() }) else el.typeName());
        const src = el.source();
        const files = p.files();
        if (src.file < files.len) if (s.previewFilePath(a, p, src.file)) |path| {
            try js.objectField("uri");
            try js.write(try pathToUri(a, path));
            try js.objectField("range");
            try s.writeRange(js, files[src.file].source, src.span);
        };
        try js.endObject();
    }

    /// The absolute path of a file of the previewed program (null for the
    /// built-in widgets).
    fn previewFilePath(s: *Server, a: Allocator, p: *Preview, file: u16) ?[]const u8 {
        const files = p.files();
        if (file >= files.len) return null;
        if (file == 0) return p.path;
        if (compiler.std_widgets.isStd(files[file].name)) return s.stdPath(a, files[file].name);
        return std.fs.path.resolve(a, &.{ std.fs.path.dirname(p.path) orelse ".", files[file].name }) catch null;
    }

    fn previewInspect(s: *Server, a: Allocator, id: json.Value, params: json.Value) !void {
        const p = s.preview orelse return s.respondNull(id);
        const elements = try p.elementsAt(getFloat(params, "x"), getFloat(params, "y"), a);
        // The innermost visible element written in the previewed file (input
        // areas like TouchArea usually cover what they belong to), else
        // the innermost one.
        var chosen: ?usize = if (elements.len > 0) elements.len - 1 else null;
        var fallback: ?usize = null;
        var i = elements.len;
        while (i > 0) {
            i -= 1;
            if (elements[i].source().file != 0) continue;
            const t = elements[i].typeName();
            if (std.mem.eql(u8, t, "TouchArea") or std.mem.eql(u8, t, "FocusScope")) {
                if (fallback == null) fallback = i;
                continue;
            }
            chosen = i;
            fallback = null;
            break;
        }
        if (fallback) |f| chosen = f;
        p.select(if (chosen) |c| elements[c] else null);
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.beginObject();
        try m.js.objectField("elements");
        try m.js.beginArray();
        for (elements) |el| try s.writeElement(a, &m.js, p, el);
        try m.js.endArray();
        try m.js.objectField("index");
        try m.js.write(chosen);
        try s.writeSelection(a, &m.js, p);
        try m.js.endObject();
        try s.finish(&m);
        try s.sendFrame(a);
    }

    fn previewSelect(s: *Server, a: Allocator, params: json.Value) !void {
        const p = s.preview orelse return;
        const uri = getString(params, "uri") orelse return;
        const path = try uriToPath(a, uri);
        const pos = getObject(params, "position") orelse return;
        const files = p.files();
        var found: ?interp.ElementRef = null;
        for (files, 0..) |f, file| {
            const fpath = s.previewFilePath(a, p, @intCast(file)) orelse continue;
            if (!std.mem.eql(u8, fpath, path)) continue;
            const offset = offsetOf(s.encoding, f.source, .{ .line = @intCast(getInt(pos, "line") orelse 0), .character = @intCast(getInt(pos, "character") orelse 0) });
            found = p.elementAtSource(@intCast(file), offset);
            break;
        }
        p.select(found);
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.notification("zigulee/previewSelection");
        try m.js.beginObject();
        try s.writeSelection(a, &m.js, p);
        try m.js.endObject();
        try s.finish(&m);
        try s.sendFrame(a);
    }

    const SourceEdit = struct { path: []const u8, source: []const u8, span: Span, text: []const u8 };

    /// How to write `name: value` on the element in its source: replace its
    /// binding's value, else the declared property's initial value, else
    /// add a binding. Null for elements in built-in files.
    fn sourceEdit(s: *Server, a: Allocator, p: *Preview, sel: interp.ElementRef, name: []const u8, value: []const u8) !?SourceEdit {
        const src = sel.source();
        const files = p.files();
        if (src.file >= files.len or compiler.std_widgets.isStd(files[src.file].name)) return null;
        const path = s.previewFilePath(a, p, src.file) orelse return null;
        const source = files[src.file].source;
        const el = sel.elem.ast;
        for (el.members) |m| if (m == .binding and std.mem.eql(u8, m.binding.name.name, name))
            return .{ .path = path, .source = source, .span = m.binding.value.span, .text = value };
        // The component's own declaration, for its root element.
        if (sel.elem == sel.inst.comp.root and sel.inst.comp.template == .none) {
            for (el.members) |m| if (m == .property and std.mem.eql(u8, m.property.name.name, name)) {
                if (m.property.alias != null) break;
                if (m.property.init) |init_expr| return .{ .path = path, .source = source, .span = init_expr.span, .text = value };
                const after_name = m.property.name.span.end;
                return .{ .path = path, .source = source, .span = .{ .start = after_name, .end = after_name }, .text = try std.fmt.allocPrint(a, ": {s}", .{value}) };
            };
        }
        // A new binding, after the opening brace.
        const brace = el.span.start + @as(u32, @intCast(std.mem.indexOfScalar(u8, source[el.span.start..el.span.end], '{') orelse return null)) + 1;
        const one_line = std.mem.indexOfScalar(u8, source[el.span.start..el.span.end], '\n') == null;
        const text = if (one_line) try std.fmt.allocPrint(a, " {s}: {s};", .{ name, value }) else blk: {
            const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..el.span.start], '\n')) |n| n + 1 else 0;
            var indent_end = line_start;
            while (indent_end < source.len and (source[indent_end] == ' ' or source[indent_end] == '\t')) indent_end += 1;
            break :blk try std.fmt.allocPrint(a, "\n{s}    {s}: {s};", .{ source[line_start..indent_end], name, value });
        };
        return .{ .path = path, .source = source, .span = .{ .start = brace, .end = brace }, .text = text };
    }

    fn previewSetProperty(s: *Server, a: Allocator, id: json.Value, params: json.Value) !void {
        const p = s.preview orelse return s.respondNull(id);
        const sel = p.selected orelse return s.respondError(id, -32602, "no element is selected");
        const name = getString(params, "name") orelse return s.respondError(id, -32602, "missing name");
        const value = getString(params, "value") orelse return s.respondError(id, -32602, "missing value");
        const problem = try interp.Inspect.setProperty(sel, name, value, a);
        // The same change as a source edit, for the editor to apply.
        const edit = if (problem == null) try s.sourceEdit(a, p, sel, name, value) else null;
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.beginObject();
        try m.js.objectField("error");
        try m.js.write(problem);
        try m.js.objectField("edit");
        if (edit) |e| {
            try m.js.beginObject();
            try m.js.objectField("changes");
            try m.js.beginObject();
            try m.js.objectField(try s.uriFor(a, e.path));
            try m.js.beginArray();
            try m.js.beginObject();
            try m.js.objectField("range");
            try s.writeRange(&m.js, e.source, e.span);
            try m.js.objectField("newText");
            try m.js.write(e.text);
            try m.js.endObject();
            try m.js.endArray();
            try m.js.endObject();
            try m.js.endObject();
        } else try m.js.write(null);
        try s.writeSelection(a, &m.js, p);
        try m.js.endObject();
        try s.finish(&m);
        try s.sendFrame(a);
    }

    // ---- Completion ----

    pub const Item = struct { label: []const u8, kind: u8, detail: []const u8 };

    fn completionKind(k: compiler.index.Kind) u8 {
        return switch (k) {
            .component, .builtin_element => 7, // Class
            .global => 9, // Module
            .property => 10, // Property
            .callback => 23, // Event
            .function => 3, // Function
            .id => 6, // Variable
            .structure => 22, // Struct
            .enumeration => 20, // EnumMember (values) / Enum
            .state => 20, // EnumMember: one of the machine's states
            .event => 23, // Event
        };
    }

    fn completion(s: *Server, a: Allocator, id: json.Value, params: json.Value) !void {
        const p = s.at(params) orelse return s.respondNull(id);
        var items: std.ArrayList(Item) = .empty;
        const ctx = completionContext(a, p.doc.text, p.offset) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (p.doc.analysis) |analysis| try collectCompletions(a, &analysis.index, ctx, &items) else try collectCompletions(a, null, ctx, &items);
        var m: Message = undefined;
        m.init(s.gpa);
        defer m.deinit();
        try m.response(id);
        try m.js.beginArray();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (items.items) |it| {
            if ((try seen.getOrPut(a, it.label)).found_existing) continue;
            try m.js.write(it);
        }
        try m.js.endArray();
        try s.finish(&m);
    }
};

/// What surrounds the cursor, found from the text (which may not parse).
pub const CompletionContext = struct {
    /// The name before a `.` right before the cursor (`root`, an id...).
    object: ?[]const u8 = null,
    /// The innermost element's type, and the component being declared.
    element: ?[]const u8 = null,
    component: ?[]const u8 = null,
    /// Inside a handler or a binding's value.
    in_code: bool = false,
    /// At the start of a member (where property names and elements go).
    statement_start: bool = true,
};

pub fn completionContext(a: Allocator, text: []const u8, offset: u32) Allocator.Error!CompletionContext {
    var ctx: CompletionContext = .{};
    // The word being typed, and an object before a dot.
    var start: usize = @min(offset, text.len);
    while (start > 0 and isNameChar(text[start - 1])) start -= 1;
    if (start > 0 and text[start - 1] == '.') {
        var o = start - 1;
        while (o > 0 and isNameChar(text[o - 1])) o -= 1;
        if (o < start - 1) ctx.object = text[o .. start - 1];
    }

    const Entry = struct { kind: enum { element, code, other }, type_name: ?[]const u8 = null };
    var stack: std.ArrayList(Entry) = .empty;
    var tokens: std.ArrayList(lexer.Token) = .empty;
    var lx: lexer.Lexer = .initRange(text, 0, @intCast(start));
    // Tokens of the current statement.
    var statement_len: usize = 0;
    var statement_code = false;
    while (true) {
        const t = lx.next();
        if (t.tag == .eof) break;
        try tokens.append(a, t);
        const n = tokens.items.len;
        const prev: ?lexer.Token = if (n >= 2) tokens.items[n - 2] else null;
        switch (t.tag) {
            .l_brace => {
                const parent = if (stack.items.len > 0) stack.items[stack.items.len - 1].kind else .other;
                var entry: Entry = .{ .kind = .other };
                if (parent == .code or statement_code and prev != null and prev.?.tag != .identifier) {
                    entry.kind = .code;
                } else if (prev) |pt| switch (pt.tag) {
                    .fat_arrow => entry.kind = .code,
                    .identifier => {
                        const word = pt.text(text);
                        if (stack.items.len == 0) {
                            // `component X inherits Y {`, `global X {`.
                            if (n >= 4 and std.mem.eql(u8, tokens.items[n - 3].text(text), "inherits")) {
                                ctx.component = tokens.items[n - 4].text(text);
                                entry = .{ .kind = .element, .type_name = word };
                            } else if (n >= 3 and std.mem.eql(u8, tokens.items[n - 3].text(text), "global")) {
                                ctx.component = word;
                                entry = .{ .kind = .element };
                            } else if (n >= 3 and std.mem.eql(u8, tokens.items[n - 3].text(text), "component")) {
                                ctx.component = word;
                                entry = .{ .kind = .element, .type_name = "Empty" };
                            }
                        } else if (parent == .element) {
                            entry = .{ .kind = .element, .type_name = word };
                        }
                    },
                    // `when cond : {`: a state sets the element's properties.
                    .colon => if (parent == .element) {
                        entry = .{ .kind = .element, .type_name = stack.items[stack.items.len - 1].type_name };
                    },
                    else => {},
                };
                try stack.append(a, entry);
                statement_len = 0;
                statement_code = false;
            },
            .r_brace => {
                _ = stack.pop();
                statement_len = 0;
                statement_code = false;
            },
            .semicolon => {
                statement_len = 0;
                statement_code = false;
            },
            .colon, .fat_arrow, .equal, .two_way => {
                statement_len += 1;
                statement_code = true;
            },
            else => statement_len += 1,
        }
    }
    var i = stack.items.len;
    while (i > 0) {
        i -= 1;
        if (stack.items[i].kind == .element) {
            ctx.element = stack.items[i].type_name;
            break;
        }
    }
    const inner = if (stack.items.len > 0) stack.items[stack.items.len - 1].kind else .other;
    ctx.in_code = inner == .code or statement_code;
    ctx.statement_start = statement_len == 0 and inner != .code;
    return ctx;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn typeKey(a: Allocator, ix: *const Index, name: []const u8) Allocator.Error!?[]const u8 {
    if (types.findBuiltin(name) != null) return try std.fmt.allocPrint(a, "builtin:{s}", .{name});
    if (ix.scopes.get(0)) |scope| for (scope) |m| if (std.mem.eql(u8, m.name, name)) return m.target;
    return null;
}

fn addMembers(a: Allocator, items: *std.ArrayList(Server.Item), members: []const compiler.index.Member) Allocator.Error!void {
    for (members) |m| try items.append(a, .{ .label = m.name, .kind = Server.completionKind(m.kind), .detail = m.detail });
}

pub fn collectCompletions(a: Allocator, index: ?*const Index, ctx: CompletionContext, items: *std.ArrayList(Server.Item)) Allocator.Error!void {
    if (ctx.object) |obj| {
        if (std.mem.eql(u8, obj, "anchors") and !ctx.in_code) {
            for (compiler.anchors.names) |n| try items.append(a, .{ .label = n[0], .kind = 10, .detail = n[1] });
            return;
        }
        if (std.mem.eql(u8, obj, "Key")) {
            for (types.key_names) |k| try items.append(a, .{ .label = k[0], .kind = 21, .detail = "key" });
            return;
        }
        const ix = index orelse return;
        const comp_key: ?[]const u8 = if (ctx.component) |c| try typeKey(a, ix, c) else null;
        var key: ?[]const u8 = null;
        if (std.mem.eql(u8, obj, "root")) {
            key = comp_key;
        } else if (std.mem.eql(u8, obj, "self")) {
            if (ctx.element) |e| key = try typeKey(a, ix, e);
        } else {
            if (comp_key) |ck| if (ix.ids.get(ck)) |ids| for (ids) |idm| if (std.mem.eql(u8, idm.name, obj)) {
                key = idm.target;
            };
            if (key == null) key = try typeKey(a, ix, obj); // a global or an enum
        }
        if (key) |k| if (ix.members.get(k)) |members| try addMembers(a, items, members);
        return;
    }

    // Members of the current element.
    if (index) |ix| if (ctx.element) |e| if (try typeKey(a, ix, e)) |k| if (ix.members.get(k)) |members| try addMembers(a, items, members);
    if (ctx.statement_start and !ctx.in_code) {
        // Element types and member keywords.
        for (types.builtins) |b| if (!b.window) try items.append(a, .{ .label = b.name, .kind = 7, .detail = "built-in element" });
        if (index) |ix| if (ix.scopes.get(0)) |scope| for (scope) |m| if (m.kind == .component) {
            try items.append(a, .{ .label = m.name, .kind = 7, .detail = m.detail });
        };
        for ([_][]const u8{ "var", "var in", "var out", "var in-out", "callback", "animate", "states", "for", "if", "changed", "anchors" }) |k|
            try items.append(a, .{ .label = k, .kind = 14, .detail = "keyword" });
        return;
    }
    // Expressions: ids, the root's members, globals and enums, functions.
    if (index) |ix| {
        if (ctx.component) |c| if (try typeKey(a, ix, c)) |ck| {
            if (ix.ids.get(ck)) |ids| try addMembers(a, items, ids);
            if (ix.members.get(ck)) |members| try addMembers(a, items, members);
        };
        if (ix.scopes.get(0)) |scope| for (scope) |m| if (m.kind == .global or m.kind == .enumeration) {
            try items.append(a, .{ .label = m.name, .kind = Server.completionKind(m.kind), .detail = m.detail });
        };
    }
    for (types.global_functions) |f| try items.append(a, .{ .label = f, .kind = 3, .detail = "function" });
    for ([_][]const u8{ "root", "self", "parent", "true", "false", "Key" }) |k| try items.append(a, .{ .label = k, .kind = 14, .detail = "" });
}

// ---- JSON helpers ----

fn getObject(v: json.Value, key: []const u8) ?json.Value {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .object) x else null;
}

fn getString(v: json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn getFloat(v: json.Value, key: []const u8) f32 {
    if (v != .object) return 0;
    const x = v.object.get(key) orelse return 0;
    return switch (x) {
        .float => |f| @floatCast(f),
        .integer => |n| @floatFromInt(n),
        else => 0,
    };
}

fn getBool(v: json.Value, key: []const u8) bool {
    if (v != .object) return false;
    const x = v.object.get(key) orelse return false;
    return x == .bool and x.bool;
}

fn getInt(v: json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .integer) x.integer else null;
}

fn getArray(v: json.Value, key: []const u8) ?[]json.Value {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .array) x.array.items else null;
}

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name, 0..) |c, i| {
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        // Dashes join words: `my-name`.
        if (c == '-' and i + 1 < name.len and (std.ascii.isAlphabetic(name[i + 1]) or name[i + 1] == '_')) continue;
        return false;
    }
    return true;
}

// ---- URIs ----

/// `file:///a%20b/c.zge` -> `/a b/c.zge` (`C:/x` on Windows).
pub fn uriToPath(gpa: Allocator, uri: []const u8) Allocator.Error![]u8 {
    const prefix = "file://";
    const rest = if (std.mem.startsWith(u8, uri, prefix)) uri[prefix.len..] else uri;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |b| {
                try out.append(gpa, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, rest[i]);
    }
    // `/C:/x` -> `C:/x`.
    if (out.items.len >= 3 and out.items[0] == '/' and std.ascii.isAlphabetic(out.items[1]) and out.items[2] == ':') _ = out.orderedRemove(0);
    // On Windows, spelled as std.fs.path spells paths (`C:\x`: backslashes,
    // an uppercase drive letter), so that they compare equal to the paths
    // of files found in the workspace or imported.
    if (@import("builtin").os.tag == .windows) {
        defer out.deinit(gpa);
        return std.fs.path.resolve(gpa, &.{out.items});
    }
    return out.toOwnedSlice(gpa);
}

pub fn pathToUri(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    if (path.len >= 2 and path[1] == ':') try out.append(gpa, '/');
    for (path) |c| {
        const keep = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-._~:", c) != null;
        if (keep) {
            try out.append(gpa, if (c == '\\') '/' else c);
        } else if (c == '\\') {
            try out.append(gpa, '/');
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(gpa);
}
