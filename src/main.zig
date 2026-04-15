const std = @import("std");

const default_host = "localhost";
const default_port: u16 = 9122;

const usage_text =
    \\Usage: pbm [options] <command> [args...]
    \\
    \\Options:
    \\  --host <host>   Server host (default: localhost)
    \\  --port <port>   Server port (default: 9122)
    \\  --help, -h      Show this help message
    \\
    \\Commands:
    \\  ping                Check if the server is reachable
    \\  status              Show server status
    \\  info [package]      Show service info or package details
    \\  list                List available packages
    \\  fetch <git_url>     Mirror a Git repository on the server
    \\  update              Sync local state with the package source
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

fn httpRequest(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    token: ?[]const u8,
) !struct { status: std.http.Status, body: []u8 } {
    const uri = std.Uri.parse(url) catch fatal("invalid URL: {s}", .{url});

    var body_writer = std.io.Writer.Allocating.init(allocator);
    errdefer body_writer.deinit();

    var auth_buf: [600]u8 = undefined;
    var headers: [2]std.http.Header = undefined;
    var headers_len: usize = 0;

    if (payload != null and method == .POST) {
        headers[headers_len] = .{ .name = "Content-Type", .value = "application/json" };
        headers_len += 1;
    }
    if (token) |t| {
        const val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch fatal("token too long", .{});
        headers[headers_len] = .{ .name = "Authorization", .value = val };
        headers_len += 1;
    }

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = method,
        .payload = payload,
        .extra_headers = headers[0..headers_len],
        .response_writer = &body_writer.writer,
    });

    var body_list = body_writer.toArrayList();
    defer body_list.deinit(allocator);
    const body = try allocator.dupe(u8, body_list.items);
    return .{ .status = result.status, .body = body };
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

    printStdout(allocator,
        \\service    {s}  ({s})
        \\
        \\update     {s}
        \\packages   {d} total  ·  {d} probed  ·  {d} synced
        \\source     {d} packages
        \\tarballs   {d} present  ·  {d} created
        \\repos      {d} scanned
        \\
    , .{ service, release, state, total, probed, synced, source_pkgs, tarballs_present, tarballs_created, repos_scanned });
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

fn renderFetch(allocator: std.mem.Allocator, body: []const u8) void {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) {
        writeStdout("queued\n");
        return;
    }
    // Try to parse JSON and show a friendly message
    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
        defer parsed.deinit();
        const root = parsed.value;
        if (root.object.get("status")) |s| {
            if (s == .string) {
                printStdout(allocator, "{s}\n", .{s.string});
                return;
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

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn cmdPing(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/status");
    defer allocator.free(url);

    const res = httpRequest(allocator, client, .GET, url, null, null) catch |err| {
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

fn cmdStatus(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/status");
    defer allocator.free(url);

    const res = httpRequest(allocator, client, .GET, url, null, null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    checkStatus(allocator, res.status, res.body);
    renderStatus(allocator, res.body);
}

fn cmdInfo(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config, package: ?[]const u8) !void {
    const path = if (package) |pkg|
        try std.fmt.allocPrint(allocator, "/api/info/{s}", .{pkg})
    else
        try allocator.dupe(u8, "/api/status");
    defer allocator.free(path);

    const url = try buildUrl(allocator, cfg.base_url, path);
    defer allocator.free(url);

    const res = httpRequest(allocator, client, .GET, url, null, null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    checkStatus(allocator, res.status, res.body);

    if (package != null) {
        renderPackageInfo(allocator, res.body);
    } else {
        renderStatus(allocator, res.body);
    }
}

fn cmdList(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/list");
    defer allocator.free(url);

    const res = httpRequest(allocator, client, .GET, url, null, null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    checkStatus(allocator, res.status, res.body);
    renderList(allocator, res.body);
}

fn cmdFetch(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config, git_url: []const u8) !void {
    if (cfg.token == null)
        writeStderr("warning: PACKBASE_TOKEN not set; request may be rejected by server\n");

    const url = try buildUrl(allocator, cfg.base_url, "/api/fetch");
    defer allocator.free(url);

    const body = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{git_url});
    defer allocator.free(body);

    const res = httpRequest(allocator, client, .POST, url, body, cfg.token) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    checkStatus(allocator, res.status, res.body);
    renderFetch(allocator, res.body);
}

fn cmdUpdate(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/update");
    defer allocator.free(url);

    // POST /api/update has no request body; pass "" so the HTTP client
    // sends Content-Length: 0 instead of trying sendBodiless() on a POST.
    const res = httpRequest(allocator, client, .POST, url, "", null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    checkStatus(allocator, res.status, res.body);
    renderUpdate(allocator, res.body);
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

    var client = std.http.Client{ .allocator = allocator };
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
