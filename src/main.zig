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
    \\  status              Show server status (/api/status)
    \\  info [package]      Show service info or package info (/api/info[/package])
    \\  list                List available packages (/api/list)
    \\  fetch <git_url>     Mirror a Git repository on the server (/api/fetch)
    \\  update              Sync local state with the package source (/api/update)
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
    \\  pbm info ziglang/zig
    \\  pbm fetch https://github.com/ziglang/zig
    \\  pbm update
    \\  pbm clone ziglang/zig
    \\
;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const Config = struct {
    base_url: []const u8,
    token: ?[]const u8,
    /// Whether base_url was heap-allocated (must be freed)
    owns_base_url: bool,
    owns_token: bool,
};

/// Parse a single .pbmrc file into the config fields.
/// File format: KEY=VALUE lines, ignoring blank lines and # comments.
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
    // Layer 1: home .pbmrc (lowest priority among file configs)
    var url_from_file: ?[]u8 = null;
    var token_from_file: ?[]u8 = null;

    if (std.process.getEnvVarOwned(allocator, "HOME") catch null) |home| {
        defer allocator.free(home);
        const home_rc = try std.fmt.allocPrint(allocator, "{s}/.pbmrc", .{home});
        defer allocator.free(home_rc);
        parsePbmrc(allocator, home_rc, &url_from_file, &token_from_file);
    }

    // Layer 2: PWD .pbmrc (overrides home)
    {
        const cwd_buf = try allocator.alloc(u8, std.fs.max_path_bytes);
        defer allocator.free(cwd_buf);
        if (std.process.getCwd(cwd_buf) catch null) |cwd| {
            const cwd_rc = try std.fmt.allocPrint(allocator, "{s}/.pbmrc", .{cwd});
            defer allocator.free(cwd_rc);
            parsePbmrc(allocator, cwd_rc, &url_from_file, &token_from_file);
        }
    }

    // Layer 3: env vars (override file config)
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

    // Layer 4: CLI flags (highest priority)
    const base_url: []const u8 = blk: {
        if (host != null or port != null) {
            // CLI flags take precedence
            if (url_from_file) |old| allocator.free(old);
            url_from_file = null;
            const h = host orelse default_host;
            const p = port orelse default_port;
            const built = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ h, p });
            break :blk built;
        }
        if (url_from_file) |u| break :blk u;
        // Default
        const built = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ default_host, default_port });
        break :blk built;
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
// Output helpers (Zig 0.15 compatible)
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
    const msg = std.fmt.bufPrint(&buf, "error: " ++ fmt ++ "\n", args) catch
        "error: (message too long)\n";
    writeStderr(msg);
    std.process.exit(1);
}

fn printUsageAndExit() noreturn {
    writeStderr(usage_text);
    std.process.exit(1);
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

fn buildUrl(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, base, "/");
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, path });
}

fn doGet(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    token: ?[]const u8,
) !struct { status: std.http.Status, body: []u8 } {
    const uri = std.Uri.parse(url) catch fatal("invalid URL: {s}", .{url});

    var body_writer = std.io.Writer.Allocating.init(allocator);
    errdefer body_writer.deinit();

    var auth_buf: [600]u8 = undefined;
    const extra: []const std.http.Header = if (token) |t| blk: {
        const val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch
            fatal("token too long", .{});
        break :blk &[_]std.http.Header{
            .{ .name = "Authorization", .value = val },
        };
    } else &.{};

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .extra_headers = extra,
        .response_writer = &body_writer.writer,
    });

    var body_list = body_writer.toArrayList();
    defer body_list.deinit(allocator);
    const body = try allocator.dupe(u8, body_list.items);
    return .{ .status = result.status, .body = body };
}

fn doPost(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
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

    if (payload != null) {
        headers[headers_len] = .{ .name = "Content-Type", .value = "application/json" };
        headers_len += 1;
    }
    if (token) |t| {
        const val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch
            fatal("token too long", .{});
        headers[headers_len] = .{ .name = "Authorization", .value = val };
        headers_len += 1;
    }

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .payload = payload,
        .extra_headers = headers[0..headers_len],
        .response_writer = &body_writer.writer,
    });

    var body_list = body_writer.toArrayList();
    defer body_list.deinit(allocator);
    const body = try allocator.dupe(u8, body_list.items);
    return .{ .status = result.status, .body = body };
}

fn printHttpResponse(allocator: std.mem.Allocator, status: std.http.Status, body: []const u8) void {
    const code: u16 = @intFromEnum(status);

    if (code >= 400) {
        printStderr(allocator, "server error {d}: {s}\n", .{ code, body });
        std.process.exit(1);
    }

    if (body.len == 0) {
        printStdout(allocator, "ok ({d})\n", .{code});
        return;
    }

    writeStdout(body);
    if (body[body.len - 1] != '\n') writeStdout("\n");
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn cmdPing(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/info");
    defer allocator.free(url);

    const res = doGet(allocator, client, url, null) catch |err| {
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

    const res = doGet(allocator, client, url, null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    printHttpResponse(allocator, res.status, res.body);
}

fn cmdInfo(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config, package: ?[]const u8) !void {
    const path = if (package) |pkg|
        try std.fmt.allocPrint(allocator, "/api/info/{s}", .{pkg})
    else
        try allocator.dupe(u8, "/api/info");
    defer allocator.free(path);

    const url = try buildUrl(allocator, cfg.base_url, path);
    defer allocator.free(url);

    const res = doGet(allocator, client, url, null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    printHttpResponse(allocator, res.status, res.body);
}

fn cmdList(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/list");
    defer allocator.free(url);

    const res = doGet(allocator, client, url, null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    printHttpResponse(allocator, res.status, res.body);
}

fn cmdFetch(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config, git_url: []const u8) !void {
    if (cfg.token == null) {
        writeStderr("warning: PACKBASE_TOKEN not set; request may be rejected by server\n");
    }

    const url = try buildUrl(allocator, cfg.base_url, "/api/fetch");
    defer allocator.free(url);

    const body = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{git_url});
    defer allocator.free(body);

    const res = doPost(allocator, client, url, body, cfg.token) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    printHttpResponse(allocator, res.status, res.body);
}

fn cmdUpdate(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config) !void {
    const url = try buildUrl(allocator, cfg.base_url, "/api/update");
    defer allocator.free(url);

    const res = doPost(allocator, client, url, null, null) catch |err|
        fatal("request failed: {s}", .{@errorName(err)});
    defer allocator.free(res.body);

    printHttpResponse(allocator, res.status, res.body);
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

    // Parse global flags
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
