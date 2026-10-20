// Libraries loaded at run time on Linux.
//
// The executable links only libc and libX11. Everything else (Vulkan,
// libcurl, OpenSSL, libsecret, fontconfig, XRandR) is opened with dlopen by
// its versioned soname: building then needs no -dev packages for them, the
// sonames that differ between distributions can be tried in turn, and a
// library that is missing turns its feature off instead of stopping the app
// from starting.
//
// A library's procedures are a struct of #c_call procedure pointers, each
// named after its C symbol (after `prefix`), filled in by dl_load:
//
//     Curl :: struct {
//         curl_easy_init: () -> *void #c_call;
//         ...
//     }
//     curl: Curl;
//     ok := dl_load(*curl, .["libcurl.so.4", "libcurl-gnutls.so.4"]);
//
// A member noted @optional may be missing (null) without failing the load.

dl_load :: (table: *$T, sonames: [] string, prefix := "") -> bool {
    for sonames {
        handle := DL.dlopen(temp_c_string(it), DL.RTLD_NOW | DL.RTLD_LOCAL);
        if !handle continue;
        if dl_fill(table, handle, prefix) return true;   // Open for good: its procedures are in the table.
        DL.dlclose(handle);
    }
    table.* = .{};
    return false;
}

// The first of `sonames` that opens, kept open; null if none does. For
// libraries whose data (not only procedures) is wanted: see dl_symbol.
dl_open :: (sonames: [] string) -> *void {
    for sonames {
        handle := DL.dlopen(temp_c_string(it), DL.RTLD_NOW | DL.RTLD_LOCAL);
        if handle return handle;
    }
    return null;
}

// A symbol's address in a library from dl_open: a variable, or a procedure.
dl_symbol :: (handle: *void, name: string) -> *void {
    return DL.dlsym(handle, temp_c_string(name));
}

// Fills `table` from an open library; false (and an empty table) if a
// symbol that isn't @optional is missing.
dl_fill :: (table: *$T, handle: *void, prefix := "") -> bool {
    return dl_fill(table, prefix, (name: *u8, data: *void) -> *void { return DL.dlsym(data, name); }, handle);
}

// Fills `table` through a lookup procedure (vkGetInstanceProcAddr...).
dl_fill :: (table: *$T, prefix: string, lookup: (name: *u8, data: *void) -> *void, data: *void) -> bool {
    info := type_info(T);
    for member: info.members {
        if member.flags & .CONSTANT continue;
        assert(member.type.type == .PROCEDURE, "dl_fill: % is not a procedure", member.name);
        symbol := lookup(temp_c_string(tprint("%1%2", prefix, member.name)), data);
        slot := cast(**void) (cast(*u8) table + member.offset_in_bytes);
        slot.* = symbol;
        if !symbol && !array_find(member.notes, "optional") {
            log_error("The library has no %.\n", tprint("%1%2", prefix, member.name));
            table.* = .{};
            return false;
        }
    }
    return true;
}

#scope_file

DL :: #import "POSIX";
