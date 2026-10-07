// HTTPS on macOS: not yet. Same interface as http_windows.jai; every request
// fails with a transport error, so the app runs in sample-data mode (-demo),
// which never reaches here. NSURLSession is the natural backend: part of the
// OS, uses the system's certificate store and proxy settings.

http_init :: (user_agent: string) -> bool {
    return true;
}

http_shutdown :: () {
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
    result.error = copy_string("Networking is not available on macOS yet. Try sample data.");
    return result;
}
