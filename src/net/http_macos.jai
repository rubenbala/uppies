// HTTPS over NSURLSession: part of macOS, uses the system's certificate
// store and proxy settings, nothing to ship. Same interface as
// http_windows.jai: requests are synchronous and run on the network worker
// threads (see up/client.jai), never on the UI thread.
//
// The session is ephemeral: no cookies, cache or credentials ever reach the
// disk. Each request hands NSURLSession a completion block, then waits on a
// semaphore that the block signals.

http_init :: (user_agent: string) -> bool {
    init_objective_c();
    init_objective_c_selector_struct(*sel);
    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);

    config := objc_call(objc_getClass("NSURLSessionConfiguration"), sel.ephemeralSessionConfiguration);
    if !config {
        log_error("Could not create an NSURLSessionConfiguration.\n");
        return false;
    }
    objc_call_float(config, sel.setTimeoutIntervalForRequest_, 30);    // Idle time while waiting for data.
    objc_call_float(config, sel.setTimeoutIntervalForResource_, 90);   // The whole request.
    objc_call(config, sel.setURLCache_, null);
    objc_call_u64(config, sel.setRequestCachePolicy_, NSURLRequestReloadIgnoringLocalCacheData);
    agent := objc_call(objc_getClass("NSDictionary"), sel.dictionaryWithObject_forKey_, NSString.getTempString(user_agent), NSString.getTempString("User-Agent"));
    objc_call(config, sel.setHTTPAdditionalHeaders_, agent);

    session = objc_call(objc_getClass("NSURLSession"), sel.sessionWithConfiguration_, config);
    if !session {
        log_error("Could not create an NSURLSession.\n");
        return false;
    }
    retain(cast(*NSObject) session);
    return true;
}

http_shutdown :: () {
    if session {
        objc_call(session, sel.invalidateAndCancel);
        release(cast(*NSObject) session);
    }
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
    // Worker threads have no autorelease pool of their own.
    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);
    S :: NSString.getTempString;

    url := NSURL.URLWithString(S(tprint("https://%1%2", host, path)));
    if !url {
        result.error = copy_string("The request's address is not valid.");
        return result;
    }
    request := objc_call(objc_getClass("NSMutableURLRequest"), sel.requestWithURL_, url);
    objc_call(request, sel.setHTTPMethod_, S(method));
    for line: split(headers, "\r\n",, temp) {
        found, name, value := split_from_left(line, ":");
        if !found continue;
        objc_call(request, sel.setValue_forHTTPHeaderField_, S(trim(value)), S(trim(name)));
    }
    if body.count {
        data := objc_call_bytes(objc_getClass("NSData"), sel.dataWithBytes_length_, body.data, cast(u64) body.count);
        objc_call(request, sel.setHTTPBody_, data);
    }

    wait: Http_Wait;
    wait.semaphore = dispatch_semaphore_create(0);
    defer dispatch_release(wait.semaphore);
    block: Http_Block;
    block.isa        = cast(*void) ObjC._NSConcreteStackBlock;
    block.invoke     = cast(*void) http_completed;
    block.descriptor = *block_descriptor;
    block.wait       = *wait;
    // The session copies the block; the copy keeps the pointer to `wait`,
    // which lives until the block has run, since we wait for it here.
    task := objc_call(session, sel.dataTaskWithRequest_completionHandler_, request, *block);
    if !task {
        result.error = copy_string("The request could not be started.");
        return result;
    }
    objc_call(task, sel.resume);
    dispatch_semaphore_wait(wait.semaphore, DISPATCH_TIME_FOREVER);
    defer {
        if wait.data     release(cast(*NSObject) wait.data);
        if wait.response release(cast(*NSObject) wait.response);
        if wait.error    release(cast(*NSObject) wait.error);
    }

    if wait.error || !wait.response return transport_error(result, wait.error);
    result.status = cast(s32) objc_call_int(wait.response, sel.statusCode);
    retry := cast(*NSString) objc_call(wait.response, sel.valueForHTTPHeaderField_, S("Retry-After"));
    if retry {
        seconds, ok := string_to_int(to_string(retry));   // The API sends seconds, not an HTTP date.
        if ok && seconds > 0 result.retry_after = cast(s32) seconds;
    }
    if wait.data {
        bytes  := NSData.bytes(wait.data);
        length := NSData.length(wait.data);
        if bytes && length result.body = copy_string(to_string(cast(*u8) bytes, cast(s64) length));
    }
    return result;
}

#scope_file

using,except(Category) ObjC :: #import "Objective_C";

session: *void;   // NSURLSession

Selectors :: struct {
    ephemeralSessionConfiguration: Selector;
    setTimeoutIntervalForRequest_: Selector;
    setTimeoutIntervalForResource_: Selector;
    setURLCache_: Selector;
    setRequestCachePolicy_: Selector;
    dictionaryWithObject_forKey_: Selector;
    setHTTPAdditionalHeaders_: Selector;
    sessionWithConfiguration_: Selector;
    invalidateAndCancel: Selector;
    requestWithURL_: Selector;
    setHTTPMethod_: Selector;
    setValue_forHTTPHeaderField_: Selector;
    dataWithBytes_length_: Selector;
    setHTTPBody_: Selector;
    dataTaskWithRequest_completionHandler_: Selector;
    resume: Selector;
    statusCode: Selector;
    valueForHTTPHeaderField_: Selector;
    code: Selector;
}
sel: Selectors;

NSURLRequestReloadIgnoringLocalCacheData :: 1;

// objc_msgSend with each signature spelled out. Not polymorphic on purpose:
// the compiler merged instantiations of polymorphic wrappers whose argument
// types differed (a pointer passed as a BOOL, or in a float register).
// Methods without a result are called through the *void ones; x0 is ignored.
objc_call :: (self: *void, s: Selector) -> *void {
    return (cast(#type (*void, Selector) -> *void #c_call) objc_msgSend)(self, s);
}
objc_call :: (self: *void, s: Selector, a: *void) -> *void {
    return (cast(#type (*void, Selector, *void) -> *void #c_call) objc_msgSend)(self, s, a);
}
objc_call :: (self: *void, s: Selector, a: *void, b: *void) -> *void {
    return (cast(#type (*void, Selector, *void, *void) -> *void #c_call) objc_msgSend)(self, s, a, b);
}
objc_call_bytes :: (self: *void, s: Selector, bytes: *void, length: u64) -> *void {
    return (cast(#type (*void, Selector, *void, u64) -> *void #c_call) objc_msgSend)(self, s, bytes, length);
}
objc_call_u64 :: (self: *void, s: Selector, a: u64) {
    (cast(#type (*void, Selector, u64) -> void #c_call) objc_msgSend)(self, s, a);
}
objc_call_float :: (self: *void, s: Selector, a: float64) {
    (cast(#type (*void, Selector, float64) -> void #c_call) objc_msgSend)(self, s, a);
}
objc_call_int :: (self: *void, s: Selector) -> s64 {
    return (cast(#type (*void, Selector) -> s64 #c_call) objc_msgSend)(self, s);
}

// What the completion block hands back to the waiting worker. Each object
// is retained, since the block's own references end when it returns.
Http_Wait :: struct {
    semaphore: *void;   // dispatch_semaphore_t
    data:      *NSData;
    response:  *void;   // NSHTTPURLResponse
    error:     *NSError;
}

// A block literal (Clang's Block ABI) with one captured pointer. No copy or
// dispose helpers: copying it copies `wait` as plain bytes.
Http_Block :: struct {
    isa:        *void;
    flags:      s32;
    reserved:   s32;
    invoke:     *void;
    descriptor: *Block_Descriptor;
    wait:       *Http_Wait;
}

Block_Descriptor :: struct {
    reserved: u64;
    size:     u64;
}

block_descriptor := Block_Descriptor.{0, size_of(Http_Block)};

// The completion handler, on the session's queue: keep the results and
// wake the worker. Nothing here allocates or needs a context.
http_completed :: (block: *Http_Block, data: *NSData, response: *void, error: *NSError) #c_call {
    wait := block.wait;
    if data     wait.data     = retain(data);
    if response wait.response = retain(cast(*NSObject) response);
    if error    wait.error    = retain(error);
    dispatch_semaphore_signal(wait.semaphore);
}

transport_error :: (result_in: Http_Result, error: *NSError) -> Http_Result {
    result := result_in;
    code: NSInteger;
    if error code = objc_call_int(error, sel.code);
    what: string;
    if code == {
        case -1001; what = "The request timed out.";
        case -1003; what = "Could not resolve api.up.com.au. Check your internet connection.";
        case -1004; what = "Could not connect to api.up.com.au.";
        case -1005; what = "The connection was closed unexpectedly.";
        case -1009; what = "This Mac is offline. Check your internet connection.";
        case;
            if code <= -1200 && code >= -1206 {
                what = "A secure connection could not be established (TLS).";
            } else if error {
                what = tprint("Network error %: %", code, to_string(NSError.localizedDescription(error)));
            } else {
                what = "The server sent no response.";
            }
    }
    result.status = 0;
    result.error = copy_string(what);
    return result;
}

libdispatch :: #library,system "libSystem";
DISPATCH_TIME_FOREVER :: 0xFFFF_FFFF_FFFF_FFFF;
dispatch_semaphore_create :: (value: s64) -> *void #foreign libdispatch;
dispatch_semaphore_wait   :: (semaphore: *void, timeout: u64) -> s64 #foreign libdispatch;
dispatch_semaphore_signal :: (semaphore: *void) -> s64 #foreign libdispatch;
dispatch_release          :: (object: *void) #foreign libdispatch;
