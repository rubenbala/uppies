// HTTPS over libcurl, which every Linux desktop has (loaded at run time:
// libcurl.so.4, or Debian's libcurl-gnutls.so.4), using the system's
// certificate store and the proxy in the environment (https_proxy), nothing
// to ship. Same interface as http_windows.jai: requests are synchronous and
// run on the network worker threads (see up/client.jai), never on the UI
// thread.
//
// Nothing reaches the disk: no cookies, no cache. Finished handles go back
// to a pool and are reused, which keeps their connections and TLS sessions
// alive between requests, as WinHTTP and NSURLSession sessions do.

http_init :: (user_agent: string) -> bool {
    if !dl_load(*curl, .["libcurl.so.4", "libcurl-gnutls.so.4"]) {
        log_error("libcurl is not installed (libcurl.so.4): Uppies can't reach the Up API.\n");
        return false;
    }
    // Not thread-safe: here, before the workers start.
    if curl.curl_global_init(CURL_GLOBAL_DEFAULT) != 0 {
        log_error("curl_global_init failed.\n");
        curl = .{};
        return false;
    }
    agent = copy_string(user_agent);
    init(*pool_mutex);
    initialized = true;
    return true;
}

http_shutdown :: () {
    if !initialized return;
    lock(*pool_mutex);
    for pool curl.curl_easy_cleanup(it);
    array_reset(*pool);
    unlock(*pool_mutex);
    initialized = false;
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
    if !initialized {
        result.error = copy_string("Networking is not available.");
        return result;
    }
    handle := take_handle();
    if !handle {
        result.error = copy_string("The request could not be started.");
        return result;
    }
    defer give_back(handle);

    header_list: *void;
    for line: split(headers, "\r\n",, temp) {
        if line.count header_list = curl.curl_slist_append(header_list, temp_c_string(line));
    }
    defer if header_list curl.curl_slist_free_all(header_list);

    received: Received;
    received.ctx = *context;
    received.body.allocator = temp;
    error_text: [CURL_ERROR_SIZE] u8;

    set :: (option: s32, value: $T) #expand {
        `ok = `ok && curl.curl_easy_setopt(`handle, option, cast,force(*void) value) == 0;
    }
    ok := true;
    set(CURLOPT_URL, temp_c_string(tprint("https://%1%2", host, path)));
    set(CURLOPT_NOSIGNAL, 1);   // Required with threads: no SIGALRM for timeouts.
    if curl.curl_easy_setopt(handle, CURLOPT_PROTOCOLS_STR, "https".data) != 0 {
        set(CURLOPT_PROTOCOLS, CURLPROTO_HTTPS);   // Before libcurl 7.85.
    }
    set(CURLOPT_FOLLOWLOCATION, 0);
    set(CURLOPT_USERAGENT, temp_c_string(agent));
    set(CURLOPT_ACCEPT_ENCODING, "".data);   // gzip and the rest curl knows: fewer bytes.
    set(CURLOPT_CONNECTTIMEOUT, 10);
    set(CURLOPT_TIMEOUT, 90);              // The whole request.
    set(CURLOPT_LOW_SPEED_LIMIT, 1);       // Less than a byte a second...
    set(CURLOPT_LOW_SPEED_TIME, 30);       // ...for 30 s is idle.
    set(CURLOPT_ERRORBUFFER, error_text.data);
    if header_list set(CURLOPT_HTTPHEADER, header_list);
    set(CURLOPT_WRITEFUNCTION, on_body);
    set(CURLOPT_WRITEDATA, *received);
    set(CURLOPT_HEADERFUNCTION, on_header);
    set(CURLOPT_HEADERDATA, *received);
    if method == "GET" {
        set(CURLOPT_HTTPGET, 1);
    } else {
        set(CURLOPT_CUSTOMREQUEST, temp_c_string(method));
        if body.count || method == "POST" || method == "PATCH" {
            set(CURLOPT_POSTFIELDSIZE_LARGE, body.count);
            set(CURLOPT_POSTFIELDS, ifx body.count then body.data else "".data);
        }
    }
    if !ok {
        result.error = copy_string("The request could not be started.");
        return result;
    }

    code := curl.curl_easy_perform(handle);
    if code != 0 return transport_error(result, code, to_string(error_text.data));

    status: s64;
    curl.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, *status);
    result.status = cast(s32) status;
    result.retry_after = received.retry_after;
    result.body = copy_string(builder_to_string(*received.body,, temp));
    return result;
}

#scope_file

Curl :: struct {
    curl_global_init:    (flags: s64) -> s32 #c_call;
    curl_easy_init:      () -> *void #c_call;
    curl_easy_cleanup:   (handle: *void) #c_call;
    curl_easy_reset:     (handle: *void) #c_call;
    // Variadic in C: every value we pass is a long, a pointer or a curl_off_t,
    // each one integer register, so a pointer parameter carries them all.
    curl_easy_setopt:    (handle: *void, option: s32, value: *void) -> s32 #c_call;
    curl_easy_perform:   (handle: *void) -> s32 #c_call;
    curl_easy_getinfo:   (handle: *void, info: s32, out: *void) -> s32 #c_call;
    curl_easy_strerror:  (code: s32) -> *u8 #c_call;
    curl_slist_append:   (list: *void, text: *u8) -> *void #c_call;
    curl_slist_free_all: (list: *void) #c_call;
}
curl: Curl;
initialized: bool;
agent: string;

// Handles not in use. A worker takes one (or makes one) per request.
pool: [..] *void;
pool_mutex: Mutex;

take_handle :: () -> *void {
    lock(*pool_mutex);
    handle: *void;
    if pool.count handle = pop(*pool);
    unlock(*pool_mutex);
    if handle curl.curl_easy_reset(handle);   // Options gone; connections and TLS sessions kept.
    else      handle = curl.curl_easy_init();
    return handle;
}

give_back :: (handle: *void) {
    lock(*pool_mutex);
    array_add(*pool, handle);
    unlock(*pool_mutex);
}

// What a request received, filled by curl's callbacks on the worker's thread.
Received :: struct {
    ctx: *#Context;
    body: String_Builder;
    retry_after: s32;
}

on_body :: (data: *u8, size: u64, count: u64, received: *Received) -> u64 #c_call {
    push_context received.ctx.* {
        append(*received.body, data, cast(s64) (size * count));
    }
    return size * count;
}

// One header line at a time, the status line first.
on_header :: (data: *u8, size: u64, count: u64, received: *Received) -> u64 #c_call {
    push_context received.ctx.* {
        line := trim(to_string(data, cast(s64) (size * count)));
        found, name, value := split_from_left(line, ":");
        if found && to_lower_copy(trim(name),, temp) == "retry-after" {
            seconds, ok := string_to_int(trim(value));   // The API sends seconds, not an HTTP date.
            if ok && seconds > 0 received.retry_after = cast(s32) seconds;
        }
    }
    return size * count;
}

transport_error :: (result_in: Http_Result, code: s32, detail: string) -> Http_Result {
    result := result_in;
    what: string;
    if code == {
        case 28; what = "The request timed out.";
        case 6;  what = "Could not resolve api.up.com.au. Check your internet connection.";
        case 7;  what = "Could not connect to api.up.com.au.";
        case 52; what = "The server sent no response.";
        case 55; #through;
        case 56; what = "The connection was closed unexpectedly.";
        case 35; #through;
        case 58; #through;
        case 59; #through;
        case 60; #through;
        case 77; #through;
        case 83; what = "A secure connection could not be established (TLS).";
        case;
            text := ifx detail then detail else to_string(curl.curl_easy_strerror(code));
            what = tprint("Network error %: %", code, text);
    }
    result.status = 0;
    result.error = copy_string(what);
    return result;
}

CURL_GLOBAL_DEFAULT :: 3;
CURL_ERROR_SIZE     :: 256;
CURLPROTO_HTTPS     :: 2;

CURLOPT_WRITEDATA            :: 10001;
CURLOPT_URL                  :: 10002;
CURLOPT_ERRORBUFFER          :: 10010;
CURLOPT_WRITEFUNCTION        :: 20011;
CURLOPT_POSTFIELDS           :: 10015;
CURLOPT_USERAGENT            :: 10018;
CURLOPT_LOW_SPEED_LIMIT      :: 19;
CURLOPT_LOW_SPEED_TIME       :: 20;
CURLOPT_HTTPHEADER           :: 10023;
CURLOPT_HEADERDATA           :: 10029;
CURLOPT_TIMEOUT              :: 13;
CURLOPT_CUSTOMREQUEST        :: 10036;
CURLOPT_FOLLOWLOCATION       :: 52;
CURLOPT_CONNECTTIMEOUT       :: 78;
CURLOPT_HEADERFUNCTION       :: 20079;
CURLOPT_HTTPGET              :: 80;
CURLOPT_NOSIGNAL             :: 99;
CURLOPT_ACCEPT_ENCODING      :: 10102;
CURLOPT_POSTFIELDSIZE_LARGE  :: 30120;
CURLOPT_PROTOCOLS            :: 181;
CURLOPT_PROTOCOLS_STR        :: 10318;

CURLINFO_RESPONSE_CODE :: 0x200000 + 2;
