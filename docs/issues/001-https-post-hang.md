# Issue: `pbm fetch` si blocca su HTTPS POST (ma GET funziona)

## Problema

`pbm fetch https://github.com/francescobianco/mush-demo` rimane appeso.
Il comando curl equivalente funziona.

## Curl funzionante

```bash
curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer p4J3ect4SPSxKzXZZgSYXeWnV7H3YtjK" \
  --data '{"url":"https://github.com/francescobianco/mush-demo"}' \
  https://pb.yafb.net/api/fetch
```

Risposta:
```json
{"status":"ok","package":"mush-demo","tag":"v0.3.0",...}
```

## Osservazioni

### Funziona
- `pbm status` (GET HTTPS) ✅
- `curl -X POST` verso `pb.yafb.net` ✅
- `curl -X POST` verso `httpbin.org` ✅
- `client.fetch()` GET verso `httpbin.org` ✅
- `client.fetch()` GET verso `pb.yafb.net` ✅
- `client.request()` POST verso `httpbin.org` (HTTP, non HTTPS) ✅
- Test locale con server mock HTTP ✅

### Non funziona (si blocca)
- `client.fetch()` POST verso `https://pb.yafb.net/api/fetch`
- `client.fetch()` POST verso `https://httpbin.org/post`
- `client.request()` POST verso `https://httpbin.org/post`

### Il blocco avviene in
Per `client.fetch()`: si blocca dopo "Starting POST request to HTTPS..." e non stampa mai "Request failed" o "Status".

Per `client.request()`: si blocca su `receiveHead()`.

## Codice attuale in `src/main.zig`

```zig
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

    var body_writer = std.io.Writer.Allocating.init(allocator);
    errdefer body_writer.deinit();

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

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = method,
        .payload = payload,
        .extra_headers = headers[0..headers_len],
        .response_writer = &body_writer.writer,
    }) catch |err| {
        if (progress_label != null) writeStderr("failed\n");
        return err;
    };

    if (progress_label != null) writeStdout("done\n");

    var body_list = body_writer.toArrayList();
    defer body_list.deinit(allocator);
    const body = try allocator.dupe(u8, body_list.items);
    return .{ .status = result.status, .body = body };
}
```

## Teorie

1. **HTTP/2 vs HTTP/1.1**: curl usa HTTP/2 per default, ma si blocca su `receiveHead()` che potrebbe essere correlato alla gestione HTTP/2 per POST.

2. **Payload con Content-Length**: Il server potrebbe aspettarsi un Content-Length specifico o la chiusura della connessione dopo l'invio del body.

3. **Chunked Transfer Encoding**: `client.fetch()` potrebbe usare chunked transfer encoding per POST che il server non gestisce correttamente.

4. **Bug in std.http.Client**: Possibile bug specifico per POST HTTPS in Zig 0.15.0.

## Prossimi passi suggeriti

1. Testare con un server locale HTTPS invece di HTTP
2. Provare a non usare `payload` ma inviare il body manualmente con `sendBody()`
3. Testare con `Transfer-Encoding: chunked` disabilitato
4. Verificare se il problema è specifico di Zig 0.15.0 o generale
5. Creare un test case minimale che riproduce il problema

## File di riferimento

- `src/main.zig`: Contiene il codice `httpRequest()`
- `test/smoke-fetch.sh`: Test locale (funziona con server HTTP)
