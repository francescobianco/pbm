const std = @import("std");

const default_host = "localhost";
const default_port: u16 = 9122;

const usage_text =
    \\Usage: pbm [options] <command> [args...]
    \\
    \\Options:
    \\  --host <host>    Server host (default: localhost)
    \\  --port <port>    Server port (default: 9122)
    \\  --print-curl     Print the equivalent curl command instead of executing
    \\  --help, -h       Show this help message
    \\
    \\Commands:
    \\  ping                Check if the server is reachable
    \\  status              Show server status
    \\  info [package]      Show service info or package details
    \\  list                List available packages
    \\  fetch <git_url>     Mirror a Git repository on the server
    \\  update              Sync local state with the package source
    \\  search <query>      Search packages by name
    \\  clone <package>     Git-clone a hosted package from the server
    \\
    \\Configuration (in order of precedence):
    \\  --host / --port flags
    \\  PACKBASE_URL env var       Base URL (e.g. http://myserver:9122)
    \\  .pbmrc in current dir      Key=value pairs
    \\  .pbmrc in home dir         Key=value pairs
    \\
    \\  PACKBASE_TOKEN env var (or .pbmrc key) is required for 'fetch'.
    \\
    \\Examples:
    \\  pbm ping
    \\  pbm status
    \\  pbm list
    \\  pbm info
    \\  pbm info raylib-zig
    \\  pbm fetch https://github.com/ziglang/zig
    \\  pbm update
    \\  pbm search raylib
    \\  pbm clone raylib-zig
    \\
;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const Config = struct {
    base_url: []const u8,
    token: ?[]const u8,
    owns_base_url: bool,
    owns_token: bool,
};

fn parsePbmrc(allocator: std.mem.Allocator, path: []const u8, out_url: *?[]u8, out_token: *?[]u8) void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1 << 20) catch return;
    defer allocator.free(content);

    var it = std.mem.splitAny(u8, content, "\n");
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "PACKBASE_URL")) {
            if (out_url.*) |old| allocator.free(old);
            out_url.* = allocator.dupe(u8, val) catch continue;
        } else if (std.mem.eql(u8, key, "PACKBASE_TOKEN")) {
            if (out_token.*) |old| allocator.free(old);
            out_token.* = allocator.dupe(u8, val) catch continue;
        }
    }
}

fn resolveConfig(allocator: std.mem.Allocator, host: ?[]const u8, port: ?u16) !Config {
    var url_from_file: ?[]u8 = null;
    var token_from_file: ?[]u8 = null;

    if (std.process.getEnvVarOwned(allocator, "HOME") catch null) |home| {
        defer allocator.free(home);
        const home_rc = try std.fmt.allocPrint(allocator, "{s}/.pbmrc", .{home});
        defer allocator.free(home_rc);
        parsePbmrc(allocator, home_rc, &url_from_file, &token_from_file);
    }

    {
        const cwd_buf = try allocator.alloc(u8, std.fs.max_path_bytes);
        defer allocator.free(cwd_buf);
        if (std.process.getCwd(cwd_buf) catch null) |cwd| {
            const cwd_rc = try std.fmt.allocPrint(allocator, "{s}/.pbmrc", .{cwd});
            defer allocator.free(cwd_rc);
            parsePbmrc(allocator, cwd_rc, &url_from_file, &token_from_file);
        }
    }

    const env_url = std.process.getEnvVarOwned(allocator, "PACKBASE_URL") catch null;
    const env_token = std.process.getEnvVarOwned(allocator, "PACKBASE_TOKEN") catch null;

    if (env_url) |u| {
        if (url_from_file) |old| allocator.free(old);
        url_from_file = u;
    }
    if (env_token) |t| {
        if (token_from_file) |old| allocator.free(old);
        token_from_file = t;
    }

    const base_url: []const u8 = blk: {
        if (host != null or port != null) {
            if (url_from_file) |old| allocator.free(old);
            url_from_file = null;
            const h = host orelse default_host;
            const p = port orelse default_port;
            break :blk try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ h, p });
        }
        if (url_from_file) |u| break :blk u;
        break :blk try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ default_host, default_port });
    };

    return Config{
        .base_url = base_url,
        .token = token_from_file,
        .owns_base_url = true,
        .owns_token = token_from_file != null,
    };
}

fn freeConfig(allocator: std.mem.Allocator, cfg: Config) void {
    if (cfg.owns_base_url) allocator.free(cfg.base_url);
    if (cfg.owns_token) if (cfg.token) |t| allocator.free(t);
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

fn writeStdout(data: []const u8) void {
    std.fs.File.stdout().writeAll(data) catch {};
}

fn writeStderr(data: []const u8) void {
    std.fs.File.stderr().writeAll(data) catch {};
}

fn printStdout(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(s);
    writeStdout(s);
}

fn printStderr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(s);
    writeStderr(s);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: " ++ fmt ++ "\n", args) catch "error: (message too long)\n";
    writeStderr(msg);
    std.process.exit(1);
}

fn printUsageAndExit() noreturn {
    writeStderr(usage_text);
    std.process.exit(1);
}

/// Format byte sizes: 511 B, 4.2 KB, 1.3 MB
fn fmtBytes(allocator: std.mem.Allocator, n: i64) []u8 {
    if (n < 1024) return std.fmt.allocPrint(allocator, "{d} B", .{n}) catch "";
    if (n < 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1} KB", .{@as(f64, @floatFromInt(n)) / 1024.0}) catch "";
    return std.fmt.allocPrint(allocator, "{d:.1} MB", .{@as(f64, @floatFromInt(n)) / (1024.0 * 1024.0)}) catch "";
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

fn buildUrl(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ std.mem.trimRight(u8, base, "/"), path });
}

fn appendShellQuoted(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\"'\"'");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

fn appendCurlPart(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, prefix: []const u8, value: []const u8) !void {
    if (out.items.len != 0) try out.append(allocator, ' ');
    if (prefix.len != 0) {
        try out.appendSlice(allocator, prefix);
        try out.append(allocator, ' ');
    }
    try appendShellQuoted(out, allocator, value);
}

fn buildCurlCommand(
    allocator: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    payload: ?[]const u8,
    token: ?[]const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "curl");

    if (!std.mem.eql(u8, method, "GET")) {
        try appendCurlPart(&out, allocator, "-X", method);
    }

    if (payload != null) {
        try appendCurlPart(&out, allocator, "-H", "Content-Type: application/json");
    }

    if (token) |t| {
        const header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{t});
        defer allocator.free(header);
        try appendCurlPart(&out, allocator, "-H", header);
    }

    if (payload) |body| {
        try appendCurlPart(&out, allocator, "--data", body);
    }

    try appendCurlPart(&out, allocator, "", url);

    return out.toOwnedSlice(allocator);
}

fn printCurlCommand(
    allocator: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    payload: ?[]const u8,
    token: ?[]const u8,
) void {
    const curl_cmd = buildCurlCommand(allocator, method, url, payload, token) catch
        fatal("failed to build curl command", .{});
    defer allocator.free(curl_cmd);
    printStdout(allocator, "{s}\n", .{curl_cmd});
}

fn buildFetchBody(allocator: std.mem.Allocator, git_url: []const u8) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(.{ .url = git_url }, .{}, &out.writer);
    return allocator.dupe(u8, out.writer.buffered());
}

fn httpRequest(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    token: ?[]const u8,
    progress_label: ?[]const u8,
) !struct { status: std.http.Status, body: []u8 } {
    const uri = std.Uri.parse(url) catch fatal("invalid URL: {s}", .{url});

    var auth_buf: [600]u8 = undefined;
    var headers: [3]std.http.Header = undefined;
    var headers_len: usize = 0;

    headers[headers_len] = .{ .name = "Accept", .value = "application/json" };
    headers_len += 1;
    if (payload != null and method == .POST) {
        headers[headers_len] = .{ .name = "Content-Type", .value = "application/json" };
        headers_len += 1;
    }
    if (token) |t| {
        const val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch fatal("token too long", .{});
        headers[headers_len] = .{ .name = "Authorization", .value = val };
        headers_len += 1;
    }

    if (progress_label) |label| {
        writeStdout(label);
        writeStdout("...\n");
    }

    // Use the lower-level request API instead of client.fetch() to work around
    // a bug in std.http.Client.fetch(): for HTTPS POST it calls body.end() which
    // only flushes the TLS write buffer into the stream buffer, but never calls
    // connection.flush() to send the encrypted data to the socket. The server
    // never receives the body, so receiveHead() deadlocks. sendBodyComplete()
    // correctly ends with r.connection.flush() which flushes both layers.
    var req = client.request(method, uri, .{
        .extra_headers = headers[0..headers_len],
        .redirect_behavior = if (payload != null and method == .POST) .unhandled else @enumFromInt(3),
    }) catch |err| {
        if (progress_label != null) writeStderr("failed\n");
        return err;
    };
    defer req.deinit();

    if (payload) |p| {
        req.sendBodyComplete(@constCast(p)) catch |err| {
            if (progress_label != null) writeStderr("failed\n");
            return err;
        };
    } else {
        req.sendBodiless() catch |err| {
            if (progress_label != null) writeStderr("failed\n");
            return err;
        };
    }

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        if (progress_label != null) writeStderr("failed\n");
        return err;
    };

    if (progress_label != null) writeStdout("done\n");

    const status = response.head.status;
    var body_list: std.ArrayList(u8) = .empty;
    errdefer body_list.deinit(allocator);
    var transfer_buf: [64]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    reader.appendRemainingUnlimited(allocator, &body_list) catch |err| switch (err) {
        error.ReadFailed => return req.reader.body_err.?,
        error.OutOfMemory => return error.OutOfMemory,
    };

    return .{ .status = status, .body = try body_list.toOwnedSlice(allocator) };
}

fn checkStatus(allocator: std.mem.Allocator, status: std.http.Status, body: []const u8) void {
    const code: u16 = @intFromEnum(status);
    if (code >= 400) {
        printStderr(allocator, "error {d}: {s}\n", .{ code, std.mem.trim(u8, body, " \t\r\n") });
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// JSON rendering helpers
// ---------------------------------------------------------------------------

fn jsonStr(v: std.json.Value, field: []const u8) []const u8 {
    if (v.object.get(field)) |f| return switch (f) {
        .string => |s| s,
        .null => "(none)",
        else => "(unknown)",
    };
    return "(missing)";
}

fn jsonInt(v: std.json.Value, field: []const u8) i64 {
    if (v.object.get(field)) |f| return switch (f) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => 0,
    };
    return 0;
}

fn jsonBool(v: std.json.Value, field: []const u8) bool {
    if (v.object.get(field)) |f| return switch (f) {
        .bool => |b| b,
        else => false,
    };
    return false;
}

fn jsonNullableStr(v: std.json.Value, field: []const u8) ?[]const u8 {
    if (v.object.get(field)) |f| return switch (f) {
        .string => |s| s,
        else => null,
    };
    return null;
}

fn jsonObjectStr(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    if (obj.get(field)) |f| return switch (f) {
        .string => |s| s,
        else => null,
    };
    return null;
}

fn jsonObjectInt(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    if (obj.get(field)) |f| return switch (f) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => null,
    };
    return null;
}

fn jsonObjectArrayLen(obj: std.json.ObjectMap, field: []const u8) ?usize {
    if (obj.get(field)) |f| return switch (f) {
        .array => |items| items.items.len,
        else => null,
    };
    return null;
}

fn firstNonNullStr(obj: std.json.ObjectMap, comptime fields: []const []const u8) ?[]const u8 {
    inline for (fields) |field| {
        if (jsonObjectStr(obj, field)) |value| return value;
    }
    return null;
}

fn firstNonNullInt(obj: std.json.ObjectMap, comptime fields: []const []const u8) ?i64 {
    inline for (fields) |field| {
        if (jsonObjectInt(obj, field)) |value| return value;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Command renderers
// ---------------------------------------------------------------------------

fn renderStatus(allocator: std.mem.Allocator, body: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        writeStdout(body);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const service = jsonStr(root, "service");
    const release = jsonStr(root, "release");

    // Top-level health counters (new in r0013+)
    const root_total = jsonInt(root, "packages_total");
    const root_healthy = jsonInt(root, "packages_healthy");
    const root_unhealthy = jsonInt(root, "packages_unhealthy");

    const upd = root.object.get("update") orelse {
        printStdout(allocator, "service  {s}  ({s})\n", .{ service, release });
        return;
    };

    const state = jsonStr(upd, "state");
    const total = jsonInt(upd, "packages_total");
    const probed = jsonInt(upd, "packages_probed");
    const synced = jsonInt(upd, "packages_synced");
    const tarballs_present = jsonInt(upd, "tarballs_present");
    const tarballs_created = jsonInt(upd, "tarballs_created");
    const repos_scanned = jsonInt(upd, "repos_scanned");
    const source_pkgs = jsonInt(upd, "source_packages");

    printStdout(allocator, "service    {s}  ({s})\n", .{ service, release });

    if (root_total > 0) {
        printStdout(allocator, "healthy    {d}/{d}  ({d} unhealthy)\n", .{ root_healthy, root_total, root_unhealthy });
    }

    printStdout(allocator,
        \\
        \\update     {s}
        \\packages   {d} total  ·  {d} probed  ·  {d} synced
        \\source     {d} packages
        \\tarballs   {d} present  ·  {d} created
        \\repos      {d} scanned
        \\
    , .{ state, total, probed, synced, source_pkgs, tarballs_present, tarballs_created, repos_scanned });
}

fn renderList(allocator: std.mem.Allocator, body: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        writeStdout(body);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Build local/registered sets for quick lookup
    var local_set = std.StringHashMap(void).init(allocator);
    defer local_set.deinit();
    var reg_set = std.StringHashMap(void).init(allocator);
    defer reg_set.deinit();

    if (root.object.get("local_packages")) |lp| {
        if (lp == .array) for (lp.array.items) |item| {
            if (item == .string) local_set.put(item.string, {}) catch {};
        };
    }
    if (root.object.get("registered_packages")) |rp| {
        if (rp == .array) for (rp.array.items) |item| {
            if (item == .string) reg_set.put(item.string, {}) catch {};
        };
    }

    const all = root.object.get("packages") orelse return;
    if (all != .array) return;

    const total = all.array.items.len;
    const local_count = local_set.count();
    const reg_count = reg_set.count();

    printStdout(allocator, "{d} packages  ({d} local, {d} registered)\n\n", .{ total, local_count, reg_count });

    for (all.array.items) |item| {
        if (item != .string) continue;
        const name = item.string;
        const is_local = local_set.contains(name);
        const is_reg = reg_set.contains(name);
        const marker: []const u8 = if (is_local and is_reg) "LR" else if (is_local) "L " else " R";
        printStdout(allocator, "  [{s}]  {s}\n", .{ marker, name });
    }

    writeStdout("\n  L = local   R = registered\n");
}

fn renderPackageInfo(allocator: std.mem.Allocator, body: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        writeStdout(body);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;

    const name = jsonStr(root, "package");
    const healthy = jsonBool(root, "healthy");
    const local = jsonBool(root, "local");
    const registered = jsonBool(root, "registered");
    const available = jsonBool(root, "available");
    const tarball_count = jsonInt(root, "tarball_count");
    const size_bytes = jsonInt(root, "size_bytes");
    const latest_tag = jsonNullableStr(root, "latest_tag");
    const smart_http = jsonBool(root, "smart_http_ready");
    const fetchable = jsonBool(root, "pseudo_git_fetchable");
    const probe_commit = jsonNullableStr(root, "fetch_probe_commit");
    const probe_err = jsonNullableStr(root, "fetch_probe_error");

    // Status flags
    var flags_buf: [64]u8 = undefined;
    var flags_fbs = std.io.fixedBufferStream(&flags_buf);
    const fw = flags_fbs.writer();
    if (healthy) fw.writeAll("healthy") catch {} else fw.writeAll("unhealthy") catch {};
    if (local) fw.writeAll("  local") catch {};
    if (registered) fw.writeAll("  registered") catch {};
    if (!available) fw.writeAll("  unavailable") catch {};
    const flags = flags_fbs.getWritten();

    printStdout(allocator, "package    {s}\nstatus     {s}\n", .{ name, flags });

    if (latest_tag) |tag| {
        const size_str = fmtBytes(allocator, size_bytes);
        defer allocator.free(size_str);
        printStdout(allocator, "latest     {s}  ({s})\n", .{ tag, size_str });
    } else {
        writeStdout("latest     (none)\n");
    }

    printStdout(allocator, "tarballs   {d}\n", .{tarball_count});

    if (root.object.get("tarballs")) |tb_val| {
        if (tb_val == .array and tb_val.array.items.len > 0) {
            writeStdout("\n");
            for (tb_val.array.items) |tb| {
                if (tb != .object) continue;
                const tag = if (tb.object.get("tag")) |t| switch (t) {
                    .string => |s| s,
                    else => "(unknown)",
                } else "(unknown)";
                const sz = if (tb.object.get("size_bytes")) |s| switch (s) {
                    .integer => |n| n,
                    else => @as(i64, 0),
                } else @as(i64, 0);
                const sz_str = fmtBytes(allocator, sz);
                defer allocator.free(sz_str);
                printStdout(allocator, "  {s:<20}  {s}\n", .{ tag, sz_str });
            }
        }
    }

    writeStdout("\n");

    // Git / fetch info
    var git_flags_buf: [64]u8 = undefined;
    var git_fbs = std.io.fixedBufferStream(&git_flags_buf);
    const gw = git_fbs.writer();
    if (smart_http) gw.writeAll("smart-http") catch {};
    if (fetchable) gw.writeAll("  fetchable") catch {};
    if (!smart_http and !fetchable) gw.writeAll("not available") catch {};
    const git_flags = git_fbs.getWritten();

    printStdout(allocator, "git        {s}\n", .{git_flags});

    if (probe_commit) |c| {
        const short = if (c.len >= 8) c[0..8] else c;
        printStdout(allocator, "commit     {s}\n", .{short});
    }
    if (probe_err) |e| {
        printStdout(allocator, "error      {s}\n", .{e});
    }
}

fn renderFetchTo(writer: anytype, allocator: std.mem.Allocator, body: []const u8, git_url: []const u8) !void {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) {
        try writer.writeAll("fetch      queued\n");
        try writer.print("source     {s}\n", .{git_url});
        return;
    }

    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
        defer parsed.deinit();
        const root = parsed.value;

        if (root == .object) {
            const obj = root.object;
            const package = firstNonNullStr(obj, &.{ "package", "name", "repo", "repository", "slug" });
            const status = firstNonNullStr(obj, &.{ "status", "state", "result" });
            const message = firstNonNullStr(obj, &.{ "message", "detail", "summary" });
            const request_id = firstNonNullStr(obj, &.{ "request_id", "job_id", "task_id", "id" });
            const tarballs = firstNonNullInt(obj, &.{ "tarballs", "tarball_count", "tags_count" }) orelse blk: {
                if (jsonObjectArrayLen(obj, "tags")) |count| break :blk @as(i64, @intCast(count));
                if (jsonObjectArrayLen(obj, "tarballs")) |count| break :blk @as(i64, @intCast(count));
                break :blk null;
            };

            const headline = message orelse status orelse "queued";
            try writer.print("fetch      {s}\n", .{headline});
            try writer.print("source     {s}\n", .{git_url});

            if (package) |value| try writer.print("package    {s}\n", .{value});
            if (status) |value| {
                if (!std.mem.eql(u8, value, headline)) try writer.print("status     {s}\n", .{value});
            }
            if (message) |value| {
                if (!std.mem.eql(u8, value, headline)) try writer.print("message    {s}\n", .{value});
            }
            if (request_id) |value| try writer.print("request    {s}\n", .{value});
            if (tarballs) |value| try writer.print("tarballs   {d}\n", .{value});
            return;
        }
    } else |_| {}

    try writer.print("fetch      queued\nsource     {s}\nresponse   {s}\n", .{ git_url, trimmed });
}

fn renderFetch(allocator: std.mem.Allocator, body: []const u8, git_url: []const u8) void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    renderFetchTo(&stdout_writer.interface, allocator, body, git_url) catch {
        writeStdout("fetch failed to render response\n");
        return;
    };
    stdout_writer.interface.flush() catch {};
}

fn renderUpdate(allocator: std.mem.Allocator, body: []const u8) void {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) {
        writeStdout("update started\n");
        return;
    }
    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
        defer parsed.deinit();
        const root = parsed.value;
        for (&[_][]const u8{ "state", "status" }) |key| {
            if (root.object.get(key)) |s| {
                if (s == .string) {
                    printStdout(allocator, "{s}\n", .{s.string});
                    return;
                }
            }
        }
        if (root.object.get("message")) |m| {
            if (m == .string) {
                printStdout(allocator, "{s}\n", .{m.string});
                return;
            }
        }
    } else |_| {}
    writeStdout(trimmed);
    writeStdout("\n");
}

fn renderSearch(allocator: std.mem.Allocator, body: []const u8, query: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        writeStdout(body);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // The response may be an array directly or an object with a "packages" field.
    const items: std.json.Array = blk: {
        if (root == .array) break :blk root.array;
        if (root.object.get("packages")) |p| {
            if (p == .array) break :blk p.array;
        }
        // Fallback: treat body as plain text
        writeStdout(body);
        return;
    };

    if (items.items.len == 0) {
        printStdout(allocator, "no packages matching \"{s}\"\n", .{query});
        return;
    }

    printStdout(allocator, "{d} package(s) matching \"{s}\"\n\n", .{ items.items.len, query });
    for (items.items) |item| {
        switch (item) {
            .string => |s| printStdout(allocator, "  {s}\n", .{s}),
            else => {},
        }
    }
    writeStdout("\n");
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn cmdPing(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/status");
    defer allocator.free(url);

    const res = httpRequest(allocator, client, .GET, url, null, null, null) catch |err| {
        printStderr(allocator, "ping failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(res.body);

    const code: u16 = @intFromEnum(res.status);
    if (code < 400) {
        writeStdout("pong\n");
    } else {
        printStdout(allocator, "server returned {d}\n", .{code});
        std.process.exit(1);
    }
}

fn cmdPingCurl(allocator: std.mem.Allocator, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/status");
    defer allocator.free(url);
    printCurlCommand(allocator, "GET", url, null, null);
}

fn cmdStatus(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/status");
    defer allocator.free(url);

    const res = httpRequest(allocator, client, .GET, url, null, null, null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    checkStatus(allocator, res.status, res.body);
    renderStatus(allocator, res.body);
}

fn cmdStatusCurl(allocator: std.mem.Allocator, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/status");
    defer allocator.free(url);
    printCurlCommand(allocator, "GET", url, null, null);
}

fn cmdInfo(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config, package: ?[]const u8) !void {
    const path = if (package) |pkg|
        try std.fmt.allocPrint(allocator, "/api/info/{s}", .{pkg})
    else
        try allocator.dupe(u8, "/api/status");
    defer allocator.free(path);

    const url = try buildUrl(allocator, cfg.base_url, path);
    defer allocator.free(url);

    const res = httpRequest(allocator, client, .GET, url, null, null, null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    checkStatus(allocator, res.status, res.body);

    if (package != null) {
        renderPackageInfo(allocator, res.body);
    } else {
        renderStatus(allocator, res.body);
    }
}

fn cmdInfoCurl(allocator: std.mem.Allocator, cfg: Config, package: ?[]const u8) !void {
    const path = if (package) |pkg|
        try std.fmt.allocPrint(allocator, "/api/info/{s}", .{pkg})
    else
        try allocator.dupe(u8, "/api/status");
    defer allocator.free(path);

    const url = try buildUrl(allocator, cfg.base_url, path);
    defer allocator.free(url);
    printCurlCommand(allocator, "GET", url, null, null);
}

fn cmdList(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/list");
    defer allocator.free(url);

    const res = httpRequest(allocator, client, .GET, url, null, null, null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    checkStatus(allocator, res.status, res.body);
    renderList(allocator, res.body);
}

fn cmdListCurl(allocator: std.mem.Allocator, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/list");
    defer allocator.free(url);
    printCurlCommand(allocator, "GET", url, null, null);
}

fn urlEncodeQuery(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(allocator, c);
        } else if (c == ' ') {
            try out.append(allocator, '+');
        } else {
            try out.writer(allocator).print("%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(allocator);
}

fn cmdSearch(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config, query: []const u8) !void {
    const encoded = try urlEncodeQuery(allocator, query);
    defer allocator.free(encoded);

    const path = try std.fmt.allocPrint(allocator, "/api/search?q={s}", .{encoded});
    defer allocator.free(path);

    const url = try buildUrl(allocator, cfg.base_url, path);
    defer allocator.free(url);

    const res = httpRequest(allocator, client, .GET, url, null, null, null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    checkStatus(allocator, res.status, res.body);
    renderSearch(allocator, res.body, query);
}

fn cmdSearchCurl(allocator: std.mem.Allocator, cfg: Config, query: []const u8) !void {
    const encoded = try urlEncodeQuery(allocator, query);
    defer allocator.free(encoded);

    const path = try std.fmt.allocPrint(allocator, "/api/search?q={s}", .{encoded});
    defer allocator.free(path);

    const url = try buildUrl(allocator, cfg.base_url, path);
    defer allocator.free(url);
    printCurlCommand(allocator, "GET", url, null, null);
}

fn cmdFetch(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config, git_url: []const u8) !void {
    if (cfg.token == null)
        writeStderr("warning: PACKBASE_TOKEN not set; request may be rejected by server\n");

    const url = try buildUrl(allocator, cfg.base_url, "/api/fetch");
    defer allocator.free(url);

    const body = try buildFetchBody(allocator, git_url);
    defer allocator.free(body);

    const res = httpRequest(allocator, client, .POST, url, body, cfg.token, "fetching") catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    checkStatus(allocator, res.status, res.body);
    renderFetch(allocator, res.body, git_url);
}

fn cmdFetchCurl(allocator: std.mem.Allocator, cfg: Config, git_url: []const u8) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/fetch");
    defer allocator.free(url);

    const body = try buildFetchBody(allocator, git_url);
    defer allocator.free(body);

    printCurlCommand(allocator, "POST", url, body, cfg.token);
}

fn cmdUpdate(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/update");
    defer allocator.free(url);

    // POST /api/update has no request body; pass "" so the HTTP client
    // sends Content-Length: 0 instead of trying sendBodiless() on a POST.
    const res = httpRequest(allocator, client, .POST, url, "", null, "updating") catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    checkStatus(allocator, res.status, res.body);
    renderUpdate(allocator, res.body);
}

fn cmdUpdateCurl(allocator: std.mem.Allocator, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/update");
    defer allocator.free(url);
    printCurlCommand(allocator, "POST", url, "", null);
}

fn cmdClone(allocator: std.mem.Allocator, cfg: Config, package: []const u8) !void {
    const base = std.mem.trimRight(u8, cfg.base_url, "/");
    const clone_url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, package });
    defer allocator.free(clone_url);

    printStdout(allocator, "cloning {s} ...\n", .{clone_url});

    var child = std.process.Child.init(&.{ "git", "clone", clone_url }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(1),
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cli_host: ?[]const u8 = null;
    var cli_port: ?u16 = null;
    var print_curl = false;
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) fatal("--host requires a value", .{});
            cli_host = args[i];
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) fatal("--port requires a value", .{});
            cli_port = std.fmt.parseInt(u16, args[i], 10) catch
                fatal("invalid port: {s}", .{args[i]});
        } else if (std.mem.eql(u8, arg, "--print-curl")) {
            print_curl = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStdout(usage_text);
            return;
        } else {
            break;
        }
    }

    if (i >= args.len) printUsageAndExit();

    const cmd = args[i];
    i += 1;

    const cfg = try resolveConfig(allocator, cli_host, cli_port);
    defer freeConfig(allocator, cfg);

    if (print_curl) {
        if (std.mem.eql(u8, cmd, "ping")) {
            try cmdPingCurl(allocator, cfg);
        } else if (std.mem.eql(u8, cmd, "status")) {
            try cmdStatusCurl(allocator, cfg);
        } else if (std.mem.eql(u8, cmd, "info")) {
            const pkg: ?[]const u8 = if (i < args.len) args[i] else null;
            try cmdInfoCurl(allocator, cfg, pkg);
        } else if (std.mem.eql(u8, cmd, "list")) {
            try cmdListCurl(allocator, cfg);
        } else if (std.mem.eql(u8, cmd, "search")) {
            if (i >= args.len) fatal("search requires a <query> argument", .{});
            try cmdSearchCurl(allocator, cfg, args[i]);
        } else if (std.mem.eql(u8, cmd, "fetch")) {
            if (i >= args.len) fatal("fetch requires a <git_url> argument", .{});
            try cmdFetchCurl(allocator, cfg, args[i]);
        } else if (std.mem.eql(u8, cmd, "update")) {
            try cmdUpdateCurl(allocator, cfg);
        } else if (std.mem.eql(u8, cmd, "clone")) {
            fatal("--print-curl is not supported for 'clone' because it does not use HTTP", .{});
        } else {
            printStderr(allocator, "unknown command: {s}\n\n", .{cmd});
            printUsageAndExit();
        }
        return;
    }

    var client = std.http.Client{ .allocator = allocator };
    client.next_https_rescan_certs = true;
    defer client.deinit();

    if (std.mem.eql(u8, cmd, "ping")) {
        try cmdPing(allocator, &client, cfg);
    } else if (std.mem.eql(u8, cmd, "status")) {
        try cmdStatus(allocator, &client, cfg);
    } else if (std.mem.eql(u8, cmd, "info")) {
        const pkg: ?[]const u8 = if (i < args.len) args[i] else null;
        try cmdInfo(allocator, &client, cfg, pkg);
    } else if (std.mem.eql(u8, cmd, "list")) {
        try cmdList(allocator, &client, cfg);
    } else if (std.mem.eql(u8, cmd, "search")) {
        if (i >= args.len) fatal("search requires a <query> argument", .{});
        try cmdSearch(allocator, &client, cfg, args[i]);
    } else if (std.mem.eql(u8, cmd, "fetch")) {
        if (i >= args.len) fatal("fetch requires a <git_url> argument", .{});
        try cmdFetch(allocator, &client, cfg, args[i]);
    } else if (std.mem.eql(u8, cmd, "update")) {
        try cmdUpdate(allocator, &client, cfg);
    } else if (std.mem.eql(u8, cmd, "clone")) {
        if (i >= args.len) fatal("clone requires a <package> argument", .{});
        try cmdClone(allocator, cfg, args[i]);
    } else {
        printStderr(allocator, "unknown command: {s}\n\n", .{cmd});
        printUsageAndExit();
    }
}

test "renderFetch formats structured response" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "status": "queued",
        \\  "message": "mirror scheduled",
        \\  "package": "mush-demo",
        \\  "request_id": "req-123",
        \\  "tarballs": 4
        \\}
    ;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try renderFetchTo(&out.writer, allocator, body, "https://github.com/francescobianco/mush-demo");

    try std.testing.expectEqualStrings(
        \\fetch      mirror scheduled
        \\source     https://github.com/francescobianco/mush-demo
        \\package    mush-demo
        \\status     queued
        \\request    req-123
        \\tarballs   4
        \\
    , out.writer.buffered());
}

test "renderFetch falls back to raw response text" {
    const allocator = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try renderFetchTo(&out.writer, allocator, "queued", "https://github.com/francescobianco/mush-demo");

    try std.testing.expectEqualStrings(
        \\fetch      queued
        \\source     https://github.com/francescobianco/mush-demo
        \\response   queued
        \\
    , out.writer.buffered());
}

test "buildCurlCommand prints fetch curl with auth and json body" {
    const allocator = std.testing.allocator;
    const body = try buildFetchBody(allocator, "https://github.com/francescobianco/mush-demo");
    defer allocator.free(body);

    const curl_cmd = try buildCurlCommand(
        allocator,
        "POST",
        "http://localhost:9122/api/fetch",
        body,
        "secret-token",
    );
    defer allocator.free(curl_cmd);

    try std.testing.expectEqualStrings(
        "curl -X 'POST' -H 'Content-Type: application/json' -H 'Authorization: Bearer secret-token' --data '{\"url\":\"https://github.com/francescobianco/mush-demo\"}' 'http://localhost:9122/api/fetch'",
        curl_cmd,
    );
}
