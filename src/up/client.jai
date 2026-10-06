// The Up API client: a queue of requests served by two worker threads.
//
// The UI thread never blocks on the network. It submits requests, and each
// frame takes whatever has completed (api_take_completed); a worker that
// finishes a request posts a message that wakes the UI loop. Two workers let
// a user action (categorising, tagging) go out while a long history sync is
// paging in the background; actions also jump the queue.
//
// In sample-data mode the same requests are answered by an in-process
// simulation of the API (demo.jai), with realistic latency, so every code
// path - paging, parsing, errors, writes - is the one used for real.

API_HOST   :: "api.up.com.au";
API_PREFIX :: "/api/v1";
PAGE_SIZE  :: 100;   // The largest page the API serves.

Api_Kind :: enum u8 {
    PING;
    ACCOUNTS;
    CATEGORIES;
    TAGS;
    TRANSACTIONS;
    TRANSACTION;
    SET_CATEGORY;
    ADD_TAG;
    REMOVE_TAG;
    WEBHOOKS;
    WEBHOOK_CREATE;
    WEBHOOK_DELETE;
    WEBHOOK_PING;
    WEBHOOK_LOGS;
    ATTACHMENT;
}

Api_Request :: struct {
    kind:    Api_Kind;
    method:  string;
    path:    string;      // On API_HOST, including the query string.
    body:    string;
    headers: string;
    demo:    bool;

    // Context for whoever handles the reply.
    generation:   u32;    // Replies from an abandoned sync are dropped.
    ref:          string; // The resource concerned (transaction or webhook id).
    arg:          string; // Category id, tag label...
    arg_int:      s64;
    window_since: s64 = -1;
    batch:        u32;    // Writes made together report as one (0: on its own).

    // Filled in by the worker.
    result:     Http_Result;
    elapsed_ms: float;
}

Api_Stats :: struct {
    requests:      s64;
    failures:      s64;
    total_ms:      float64;
    last_ms:       float;
    last_status:   s32;
    last_error:    string;   // Heap.
    last_ok_time:  float64;  // ui clock
}

api_stats: Api_Stats;

api_init :: () -> bool {
    if !http_init("Uppies/1.0 (Windows; +https://api.up.com.au)") return false;
    init(*api.mutex);
    init(*api.semaphore);
    for * api.workers {
        thread_init(it, worker_proc);
        thread_start(it);
    }
    return true;
}

api_set_token :: (token: string) {
    free(api.auth_header);
    api.auth_header = sprint("Authorization: Bearer %\r\nAccept: application/json\r\n", token);
}

api_set_demo :: (on: bool) {
    api.demo = on;
}

api_is_demo :: () -> bool { return api.demo; }

// Builds and queues a request. `path` is relative to API_PREFIX, or an
// absolute https://api.up.com.au URL (the API's paging links).
api_submit :: (kind: Api_Kind, method: string, path: string, body := "", generation: u32 = 0, ref := "", arg := "", arg_int: s64 = 0, window_since: s64 = -1, urgent := false, batch: u32 = 0) {
    req := New(Api_Request);
    req.kind = kind;
    req.method = copy_string(method);
    full_path := path;
    ORIGIN :: "https://api.up.com.au";
    if begins_with(full_path, ORIGIN) full_path = slice(full_path, ORIGIN.count, full_path.count - ORIGIN.count);
    else full_path = tprint("%%", API_PREFIX, path);
    req.path = copy_string(full_path);
    req.body = copy_string(body);
    req.headers = ifx body.count then sprint("%Content-Type: application/json\r\n", api.auth_header) else copy_string(api.auth_header);
    req.demo = api.demo;
    req.generation = generation;
    req.ref = copy_string(ref);
    req.arg = copy_string(arg);
    req.arg_int = arg_int;
    req.window_since = window_since;
    req.batch = batch;

    lock(*api.mutex);
    if urgent array_insert_at(*api.pending, req, 0);
    else array_add(*api.pending, req);
    api.in_flight += 1;
    unlock(*api.mutex);
    signal(*api.semaphore);
}

// Completed requests, oldest first. The caller frees each with api_free.
api_take_completed :: () -> [] *Api_Request {
    result: [..] *Api_Request;
    result.allocator = temp;
    lock(*api.mutex);
    for api.completed array_add(*result, it);
    api.completed.count = 0;
    unlock(*api.mutex);

    for result {
        api_stats.requests += 1;
        api_stats.total_ms += it.elapsed_ms;
        api_stats.last_ms = it.elapsed_ms;
        api_stats.last_status = it.result.status;
        ok := it.result.status >= 200 && it.result.status < 300;
        if ok {
            api_stats.last_ok_time = ui.time;
        } else {
            api_stats.failures += 1;
            free(api_stats.last_error);
            message := ifx it.result.error.count then it.result.error else parse_api_error(it.result.body);
            if !message.count message = tprint("HTTP %", it.result.status);
            api_stats.last_error = copy_string(message);
        }
    }
    return result;
}

api_in_flight :: () -> int {
    lock(*api.mutex);
    n := api.in_flight;
    unlock(*api.mutex);
    return n;
}

api_free :: (req: *Api_Request) {
    free(req.method); free(req.path); free(req.body); free(req.headers);
    free(req.ref); free(req.arg);
    free(req.result.body); free(req.result.error);
    free(req);
}

// A readable message for a failed request.
api_error_message :: (req: *Api_Request) -> string {
    if req.result.error.count return req.result.error;
    message := parse_api_error(req.result.body);
    if message.count return message;
    if req.result.status == {
        case 401; return "The API rejected the access token (401).";
        case 404; return "Not found (404).";
        case 429; return "Too many requests: the API is rate limiting (429).";
    }
    if req.result.status >= 500 return tprint("Up's servers returned an error (%).", req.result.status);
    return tprint("Request failed (HTTP %).", req.result.status);
}

api_ok :: inline (req: *Api_Request) -> bool { return req.result.status >= 200 && req.result.status < 300; }

// "filter[since]=..." with brackets and the value percent-encoded.
query_param :: (name: string, value: string) -> string {
    return tprint("%=%", url_encode(name), url_encode(value));
}

url_encode :: (s: string) -> string {
    builder: String_Builder;
    builder.allocator = temp;
    for 0..s.count - 1 {
        c := s[it];
        unreserved := (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") || (c >= #char "0" && c <= #char "9") || c == #char "-" || c == #char "_" || c == #char "." || c == #char "~";
        if unreserved append(*builder, c);
        else print_to_builder(*builder, "%%", "%", formatInt(c, base = 16, minimum_digits = 2));
    }
    return builder_to_string(*builder,, temp);
}

#scope_file

Api_State :: struct {
    mutex:     Mutex;
    semaphore: Semaphore;
    workers:   [2] Thread;
    pending:   [..] *Api_Request;
    completed: [..] *Api_Request;
    in_flight: int;
    auth_header: string;
    demo: bool;
}

api: Api_State;

worker_proc :: (thread: *Thread) -> s64 {
    while true {
        wait_for(*api.semaphore);
        lock(*api.mutex);
        req: *Api_Request;
        if api.pending.count {
            req = api.pending[0];
            array_ordered_remove_by_index(*api.pending, 0);
        }
        unlock(*api.mutex);
        if !req continue;

        start := seconds_since_init();
        if req.demo {
            req.result = demo_execute(req.method, req.path, req.body);
        } else {
            req.result = http_request(API_HOST, req.method, req.path, req.headers, req.body);
        }
        req.elapsed_ms = cast(float) ((seconds_since_init() - start) * 1000);

        lock(*api.mutex);
        array_add(*api.completed, req);
        api.in_flight -= 1;
        unlock(*api.mutex);
        platform_wake();
        reset_temporary_storage();
    }
    return 0;
}
