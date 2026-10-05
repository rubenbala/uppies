// HTTPS over WinHTTP: part of Windows, uses the system's certificate store
// and proxy settings, nothing to ship. Requests are synchronous; they run on
// the network worker threads (see up/client.jai), never on the UI thread.

http_init :: (user_agent: string) -> bool {
    access: u32 = WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY;
    session = WinHttpOpen(utf8_to_wide(user_agent,, temp), access, null, null, 0);
    if !session {
        // Before Windows 8.1 there is no automatic proxy type.
        session = WinHttpOpen(utf8_to_wide(user_agent,, temp), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, null, null, 0);
    }
    if !session {
        log_error("WinHttpOpen failed (%).\n", GetLastError());
        return false;
    }
    WinHttpSetTimeouts(session, 10_000, 10_000, 20_000, 30_000);
    decompression: u32 = WINHTTP_DECOMPRESSION_FLAG_ALL;
    WinHttpSetOption(session, WINHTTP_OPTION_DECOMPRESSION_FLAGS, *decompression, size_of(u32));   // gzip pages: fewer bytes.
    return true;
}

http_shutdown :: () {
    if session WinHttpCloseHandle(session);
    session = null;
}

Http_Result :: struct {
    status:      s32;      // HTTP status; 0 when the request never completed.
    body:        string;   // Heap allocated (context.allocator).
    error:       string;   // Transport failure, heap allocated.
    retry_after: s32;      // Seconds, from Retry-After, if any.
}

// One request, start to finish. `headers` is CRLF-separated.
http_request :: (host: string, method: string, path: string, headers: string, body: string) -> Http_Result {
    result: Http_Result;
    if !session {
        result.error = copy_string("Networking is not available.");
        return result;
    }

    connection := WinHttpConnect(session, utf8_to_wide(host,, temp), INTERNET_DEFAULT_HTTPS_PORT, 0);
    if !connection return transport_error(result, "connect");
    defer WinHttpCloseHandle(connection);

    request := WinHttpOpenRequest(connection, utf8_to_wide(method,, temp), utf8_to_wide(path,, temp), null, null, null, WINHTTP_FLAG_SECURE);
    if !request return transport_error(result, "open request");
    defer WinHttpCloseHandle(request);

    wide_headers: *u16;
    headers_length: u32;
    if headers.count {
        wide_headers = utf8_to_wide(headers,, temp);
        headers_length = 0xFFFF_FFFF;   // Null-terminated.
    }
    if !WinHttpSendRequest(request, wide_headers, headers_length, body.data, cast(u32) body.count, cast(u32) body.count, 0) {
        return transport_error(result, "send");
    }
    if !WinHttpReceiveResponse(request, null) return transport_error(result, "receive");

    status: u32;
    size := cast(u32) size_of(u32);
    WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, null, *status, *size, null);
    result.status = cast(s32) status;

    retry: u32;
    size = size_of(u32);
    if WinHttpQueryHeaders(request, WINHTTP_QUERY_RETRY_AFTER | WINHTTP_QUERY_FLAG_NUMBER, null, *retry, *size, null) {
        result.retry_after = cast(s32) retry;
    }

    builder: String_Builder;
    builder.allocator = temp;
    buffer: [16384] u8;
    while true {
        read: u32;
        if !WinHttpReadData(request, buffer.data, buffer.count, *read) return transport_error(result, "read");
        if read == 0 break;
        append(*builder, buffer.data, read);
    }
    result.body = builder_to_string(*builder);
    return result;
}

#scope_file

session: HINTERNET;

transport_error :: (result_in: Http_Result, stage: string) -> Http_Result {
    result := result_in;
    code := GetLastError();
    what: string;
    if code == {
        case 12002; what = "The request timed out.";
        case 12007; what = "Could not resolve api.up.com.au. Check your internet connection.";
        case 12029; what = "Could not connect to api.up.com.au.";
        case 12030; what = "The connection was closed unexpectedly.";
        case 12031; what = "The connection was reset.";
        case 12175; what = "A secure connection could not be established (TLS).";
        case 12157; what = "A secure connection could not be established (TLS).";
        case;       what = tprint("Network error % during %.", code, stage);
    }
    result.status = 0;
    result.error = copy_string(what);
    return result;
}

HINTERNET :: *void;

winhttp :: #library,system "winhttp";

WINHTTP_ACCESS_TYPE_DEFAULT_PROXY   :: 0;
WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY :: 4;
WINHTTP_FLAG_SECURE                 :: 0x00800000;
INTERNET_DEFAULT_HTTPS_PORT         :: 443;
WINHTTP_QUERY_STATUS_CODE           :: 19;
WINHTTP_QUERY_RETRY_AFTER           :: 36;
WINHTTP_QUERY_FLAG_NUMBER           :: 0x20000000;
WINHTTP_OPTION_DECOMPRESSION_FLAGS  :: 118;
WINHTTP_DECOMPRESSION_FLAG_ALL      :: 3;

WinHttpOpen :: (agent: *u16, access_type: u32, proxy: *u16, proxy_bypass: *u16, flags: u32) -> HINTERNET #foreign winhttp;
WinHttpConnect :: (session: HINTERNET, server: *u16, port: u16, reserved: u32) -> HINTERNET #foreign winhttp;
WinHttpOpenRequest :: (connection: HINTERNET, verb: *u16, object_name: *u16, version: *u16, referrer: *u16, accept_types: **u16, flags: u32) -> HINTERNET #foreign winhttp;
WinHttpSendRequest :: (request: HINTERNET, headers: *u16, headers_length: u32, optional: *void, optional_length: u32, total_length: u32, ctx: u64) -> s32 #foreign winhttp;
WinHttpReceiveResponse :: (request: HINTERNET, reserved: *void) -> s32 #foreign winhttp;
WinHttpQueryHeaders :: (request: HINTERNET, info_level: u32, name: *u16, buffer: *void, buffer_length: *u32, index: *u32) -> s32 #foreign winhttp;
WinHttpReadData :: (request: HINTERNET, buffer: *void, to_read: u32, read: *u32) -> s32 #foreign winhttp;
WinHttpCloseHandle :: (handle: HINTERNET) -> s32 #foreign winhttp;
WinHttpSetTimeouts :: (handle: HINTERNET, resolve: s32, connect: s32, send: s32, receive: s32) -> s32 #foreign winhttp;
WinHttpSetOption :: (handle: HINTERNET, option: u32, buffer: *void, length: u32) -> s32 #foreign winhttp;
