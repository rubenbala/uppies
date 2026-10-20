// Linux implementation of the platform layer. Two window systems, chosen
// when the app starts:
//
// - Wayland (linux_wayland.jai), natively, in a Wayland session: when
//   WAYLAND_DISPLAY is set, unless UPPIES_X11=1 asks for X11.
// - X11 (linux_x11.jai, Xlib) in an X11 session, or through XWayland when
//   the Wayland compositor can't be used.
//
// Either way the window is drawn only by the Vulkan backend (render/vulkan),
// the main loop sleeps in poll() on the window system's connection and an
// eventfd that platform_wake writes from any thread, and everything below
// is shared: files, secrets, fonts, dialogs, links.
//
// - Secrets at rest (the token, the store file's key) are sealed with
//   AES-256-GCM (OpenSSL) under a key kept in the desktop's keyring (the
//   Secret Service: GNOME Keyring, KWallet), the counterpart of DPAPI and the
//   macOS Keychain; without a keyring, in a file only this user can read.
//
// Libraries other than libc and libX11 are loaded at run time (linux_dl.jai).

#load "linux_dl.jai";
#load "linux_x11.jai";
#load "linux_wayland.jai";

// How the UI names this platform and its parts.
PLATFORM_NAME         :: "Linux";
PLATFORM_DEVICE       :: "this computer";
PLATFORM_SECRET_STORE := "your login keyring";   // Or the key file (protect_choose_store).
PLATFORM_ACCOUNT      :: "your user account";
PLATFORM_TOKEN_STORED := "Encrypted with a key in your login keyring";
MOD_KEY               :: "Ctrl";   // As written in shortcuts: Ctrl+F.
MOD_SEPARATOR         :: "+";
MOD_CLICK             :: "Ctrl+click";
NEXT_PAGE_KEYS        :: "Ctrl+Tab";

MIN_WINDOW_WIDTH  :: 1000;   // Logical units.
MIN_WINDOW_HEIGHT :: 620;

Linux_Window_System :: enum u8 { X11; WAYLAND; }
linux_window_system: Linux_Window_System;

// Shared by the window systems.
linux_context: #Context;            // For callbacks from C.
linux_wake_fd: s32 = -1;            // platform_wake's eventfd.
linux_dark_background := true;      // The theme is dark (platform_set_dark_appearance).
linux_dialog_open: bool;            // A dialog has the keyboard and mouse: input is dropped.

platform_init :: (title: string, logical_width: int, logical_height: int) -> bool {
    linux_context = context;
    setlocale(LC_CTYPE, "");   // Text input composes in the user's locale.

    linux_wake_fd = POSIX.eventfd(0, xx ((cast(u32) POSIX.EFD.CLOEXEC) | (cast(u32) POSIX.EFD.NONBLOCK)));
    if linux_wake_fd < 0 {
        log_error("Could not create an eventfd.\n");
        return false;
    }
    protect_choose_store();

    wayland := POSIX.getenv("WAYLAND_DISPLAY") != null && to_string(POSIX.getenv("UPPIES_X11")) != "1";
    if wayland {
        if wayland_init(title, logical_width, logical_height) {
            linux_window_system = .WAYLAND;
            return true;
        }
        wayland_shutdown();
        if !POSIX.getenv("DISPLAY") return false;
        log("Using X11 (XWayland) instead.\n");
    }
    linux_window_system = .X11;
    return x11_init(title, logical_width, logical_height);
}

// Called once the first frame has been rendered.
platform_show_window :: () {
    if linux_window_system == .WAYLAND wayland_show_window();
    else x11_show_window();
}

// The window's title bar and the background shown before the first frame,
// dark or light to match the theme, where the window system lets us say.
platform_set_dark_appearance :: (dark: bool) {
    linux_dark_background = dark;
    if linux_window_system == .X11 x11_set_dark_appearance(dark);
}

platform_shutdown :: () {
    if linux_window_system == .WAYLAND wayland_shutdown();
    else x11_shutdown();
    if linux_wake_fd >= 0 POSIX.close(linux_wake_fd);
    linux_wake_fd = -1;
}

// Handles every pending event without blocking.
platform_pump_events :: () {
    if linux_window_system == .WAYLAND wayland_pump_events();
    else x11_pump_events();
}

// Sleeps until the OS has an event for us, or until timeout_seconds pass
// (negative: no timeout). An idle app costs nothing.
platform_wait_for_events :: (timeout_seconds: float64 = -1) {
    if linux_window_system == .WAYLAND wayland_wait_for_events(timeout_seconds);
    else x11_wait_for_events(timeout_seconds);
}

// Wakes the main loop from any thread (a network reply arrived).
platform_wake :: () {
    if linux_wake_fd < 0 return;
    one: u64 = 1;
    POSIX.write(linux_wake_fd, *one, size_of(u64));
}

platform_clipboard_get :: () -> string {   // Temporary storage.
    if linux_window_system == .WAYLAND return wayland_clipboard_get();
    return x11_clipboard_get();
}

platform_clipboard_set :: (text: string) {
    if linux_window_system == .WAYLAND wayland_clipboard_set(text);
    else x11_clipboard_set(text);
}

platform_set_cursor :: (cursor: Cursor) {
    if linux_window_system == .WAYLAND wayland_set_cursor(cursor);
    else x11_set_cursor(cursor);
}

platform_set_title :: (title: string) {
    if linux_window_system == .WAYLAND wayland_set_title(title);
    else x11_set_title(title);
}

// The window controls of a title bar the app draws itself, when
// platform.client_decorations says the window system draws none (Wayland
// compositors without server-side decorations: GNOME, Weston).

// Starts moving the window with the mouse, from the press that is down now.
platform_window_move :: () {
    if linux_window_system == .WAYLAND wayland_window_move();
}

platform_window_toggle_maximized :: () {
    if linux_window_system == .WAYLAND wayland_window_toggle_maximized();
}

platform_window_minimize :: () {
    if linux_window_system == .WAYLAND wayland_window_minimize();
}

// The window manager's menu for the window (move, resize, always on top...)
// at a point in the window, in pixels.
platform_window_menu :: (x: float, y: float) {
    if linux_window_system == .WAYLAND wayland_window_menu(x, y);
}

// Opens a web address in the browser, or a folder in the file manager,
// through xdg-open. Only https addresses and absolute paths are opened.
platform_open_url :: (url: string) {
    if !begins_with(url, "https://") && !begins_with(url, "/") return;
    if !spawn_detached(.["xdg-open", url]) log_error("Could not run xdg-open for %\n", url);
}

// Asks where to save a file, with the desktop's Save dialog (zenity, or
// kdialog on KDE), starting from `suggested_name`. `type_name` and
// `extension` ("PDF document", "pdf") describe the file; the dialog asks
// before replacing a file. Blocks until the dialog closes. Returns the path
// chosen (temporary storage), or false when cancelled. Without either tool,
// saves in the Documents folder under a name that is free.
platform_save_file_dialog :: (title: string, suggested_name: string, type_name: string, extension: string) -> path: string, ok: bool {
    folder := documents_dir();
    start := tprint("%/%", folder, suggested_name);
    kde := contains(to_string(POSIX.getenv("XDG_CURRENT_DESKTOP")), "KDE");
    zenity  := find_program("zenity");
    kdialog := find_program("kdialog");
    if kde && kdialog zenity = "";
    // Over our window, where the window system lets one window name another.
    parent: u64 = ifx linux_window_system == .X11 then x11_window_id() else 0;

    args: [..] string;
    args.allocator = temp;
    if zenity {
        array_add(*args, zenity, "--file-selection", "--save", "--confirm-overwrite", tprint("--title=%", title),
                  tprint("--filename=%", start), tprint("--file-filter=% | *.%", type_name, extension));
        if parent array_add(*args, tprint("--attach=%", parent));
    } else if kdialog {
        array_add(*args, kdialog, "--getsavefilename", start, tprint("% (*.%)", type_name, extension), "--title", title);
        if parent array_add(*args, "--attach", tprint("%", parent));
    } else {
        log("Neither zenity nor kdialog is installed; saving without asking.\n");
        return free_path(folder, suggested_name, extension), true;
    }

    chosen, ran := run_dialog(args);
    input_release_all();   // The dialog had the keyboard and mouse.
    platform.needs_redraw = true;
    if !ran return free_path(folder, suggested_name, extension), true;
    chosen = trim_right(chosen, "\r\n");
    if !chosen return "", false;
    if !ends_with(to_lower_copy(chosen,, temp), tprint(".%", extension)) chosen = tprint("%.%", chosen, extension);
    return chosen, true;
}

// The eventfd was written (platform_wake): reset it and draw a frame.
linux_drain_wake :: () {
    count: u64;
    POSIX.read(linux_wake_fd, *count, size_of(u64));
    platform.needs_redraw = true;
}

// A poll() timeout in milliseconds, rounded up so a wait never ends just
// before its deadline; -1 (none) for a negative one.
linux_poll_timeout :: (timeout_seconds: float64) -> s32 {
    if timeout_seconds < 0 return -1;
    return cast(s32) min(ceil(timeout_seconds * 1000), 1_000_000_000.0);
}

platform_local_time :: () -> Local_Time {
    now := POSIX.time(null);
    local: POSIX.tm;
    POSIX.localtime_r(*now, *local);
    result: Local_Time;
    result.utc_seconds    = cast(s64) now;
    result.offset_minutes = cast(s32) (local.tm_gmtoff / 60);
    return result;
}

// Per-user app directory, created on first use (mode 0700):
// $XDG_DATA_HOME/uppies, which is ~/.local/share/uppies unless set.
platform_app_data_dir :: () -> string {
    if !app_data_dir {
        base := to_string(POSIX.getenv("XDG_DATA_HOME"));
        if !base || !begins_with(base, "/") {   // The spec: relative paths are to be ignored.
            home := to_string(POSIX.getenv("HOME"));
            base = ifx home then tprint("%/.local/share", home) else exe_dir;
        }
        app_data_dir = sprint("%/uppies", base);
        make_private_directory(app_data_dir);
    }
    return app_data_dir;
}

// Points every per-user file at another folder (testing: -data-dir).
platform_set_app_data_dir :: (path: string) {
    free(app_data_dir);
    app_data_dir = copy_string(path);
    make_private_directory(app_data_dir);
}

// Secrets at rest are sealed with AES-256-GCM under a key kept in the
// user's keyring (the Secret Service), or, without one, in a file only this
// user can read: either way, only this user on this computer can open them,
// the counterpart of DPAPI. Optional `entropy` must be given again to
// decrypt, binding the secret to something else the app knows. Same layout
// as on macOS.
platform_protect :: (plain: string, entropy := "") -> string, bool {
    if !protect_load_key() return "", false;
    nonce: [AES_NONCE_SIZE] u8;
    if !platform_random_bytes(nonce) return "", false;
    cipher, tag, ok := platform_aes_gcm_encrypt(protect_key, nonce, as_bytes(protect_aad(entropy)), as_bytes(plain));
    if !ok return "", false;
    defer array_free(cipher);
    result := alloc_string(PROTECT_HEADER + cipher.count + AES_TAG_SIZE);
    memcpy(result.data, PROTECT_MAGIC.data, PROTECT_MAGIC.count);
    memcpy(result.data + PROTECT_MAGIC.count, nonce.data, AES_NONCE_SIZE);
    memcpy(result.data + PROTECT_HEADER, cipher.data, cipher.count);
    memcpy(result.data + PROTECT_HEADER + cipher.count, tag.data, AES_TAG_SIZE);
    return result, true;
}

platform_unprotect :: (cipher: string, entropy := "") -> string, bool {
    if cipher.count < PROTECT_HEADER + AES_TAG_SIZE || slice(cipher, 0, PROTECT_MAGIC.count) != PROTECT_MAGIC return "", false;
    if !protect_load_key() return "", false;
    bytes := as_bytes(cipher);
    tag: [AES_TAG_SIZE] u8;
    memcpy(tag.data, cipher.data + cipher.count - AES_TAG_SIZE, AES_TAG_SIZE);
    sealed := array_view(bytes, PROTECT_HEADER, cipher.count - PROTECT_HEADER - AES_TAG_SIZE);
    plain, ok := platform_aes_gcm_decrypt(protect_key, array_view(bytes, PROTECT_MAGIC.count, AES_NONCE_SIZE), as_bytes(protect_aad(entropy)), sealed, tag);
    if !ok return "", false;
    return to_string(plain.data, plain.count), true;   // Heap, like the Windows version: the caller frees (and wipes) it.
}

// Cryptographically secure random bytes from the kernel.
platform_random_bytes :: (out: [] u8) -> bool {
    at := 0;
    while at < out.count {
        got := getrandom(out.data + at, cast(u64) (out.count - at), 0);
        if got < 0 {
            if POSIX.errno() == POSIX.EINTR continue;
            return false;
        }
        at += got;
    }
    return true;
}

// AES-256-GCM (OpenSSL's libcrypto). `aad` is authenticated but not
// encrypted. Returns the ciphertext (same length as plain, heap) and the tag.
platform_aes_gcm_encrypt :: (key: [] u8, nonce: [] u8, aad: [] u8, plain: [] u8) -> cipher: [] u8, tag: [AES_TAG_SIZE] u8, ok: bool {
    tag: [AES_TAG_SIZE] u8;
    if key.count != AES_KEY_SIZE || nonce.count != AES_NONCE_SIZE || !crypto_load() return .[], tag, false;
    ctx := crypto.EVP_CIPHER_CTX_new();
    if !ctx return .[], tag, false;
    defer crypto.EVP_CIPHER_CTX_free(ctx);
    cipher := NewArray(plain.count, u8, initialized = false);
    n: s32;
    ok := crypto.EVP_EncryptInit_ex(ctx, crypto.EVP_aes_256_gcm(), null, null, null) == 1
       && crypto.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, AES_NONCE_SIZE, null) == 1
       && crypto.EVP_EncryptInit_ex(ctx, null, null, key.data, nonce.data) == 1
       && (!aad.count   || crypto.EVP_EncryptUpdate(ctx, null, *n, aad.data, xx aad.count) == 1)
       && (!plain.count || crypto.EVP_EncryptUpdate(ctx, cipher.data, *n, plain.data, xx plain.count) == 1)
       && crypto.EVP_EncryptFinal_ex(ctx, cipher.data + plain.count, *n) == 1
       && crypto.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, AES_TAG_SIZE, tag.data) == 1;
    if !ok { array_free(cipher); return .[], tag, false; }
    return cipher, tag, true;
}

// Fails if the ciphertext, tag or aad were altered, or the key or nonce are
// wrong: nothing unauthenticated is ever returned.
platform_aes_gcm_decrypt :: (key: [] u8, nonce: [] u8, aad: [] u8, cipher: [] u8, tag: [AES_TAG_SIZE] u8) -> plain: [] u8, ok: bool {
    if key.count != AES_KEY_SIZE || nonce.count != AES_NONCE_SIZE || !crypto_load() return .[], false;
    ctx := crypto.EVP_CIPHER_CTX_new();
    if !ctx return .[], false;
    defer crypto.EVP_CIPHER_CTX_free(ctx);
    plain := NewArray(cipher.count, u8, initialized = false);
    tag_copy := tag;
    n: s32;
    ok := crypto.EVP_DecryptInit_ex(ctx, crypto.EVP_aes_256_gcm(), null, null, null) == 1
       && crypto.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, AES_NONCE_SIZE, null) == 1
       && crypto.EVP_DecryptInit_ex(ctx, null, null, key.data, nonce.data) == 1
       && (!aad.count    || crypto.EVP_DecryptUpdate(ctx, null, *n, aad.data, xx aad.count) == 1)
       && (!cipher.count || crypto.EVP_DecryptUpdate(ctx, plain.data, *n, cipher.data, xx cipher.count) == 1)
       && crypto.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, AES_TAG_SIZE, tag_copy.data) == 1
       && crypto.EVP_DecryptFinal_ex(ctx, plain.data + cipher.count, *n) > 0;
    if !ok {
        if plain.count memset(plain.data, 0, plain.count);
        array_free(plain);
        return .[], false;
    }
    return plain, true;
}

// Replaces `path` with `data` in one step: written beside it, flushed to
// disk, then renamed over it, and the rename flushed too. A crash leaves the
// old file or the new one, never a mixture.
platform_write_file_atomic :: (path: string, data: [] u8) -> bool {
    tmp := tprint("%.tmp", path);
    c_tmp := temp_c_string(tmp);
    fd := POSIX.open(c_tmp, POSIX.O_WRONLY | POSIX.O_CREAT | POSIX.O_TRUNC | POSIX.O_CLOEXEC, POSIX.S_IRUSR | POSIX.S_IWUSR);
    if fd < 0 return false;
    at := 0;
    ok := true;
    while at < data.count {
        written := POSIX.write(fd, data.data + at, cast(u64) (data.count - at));
        if written < 0 && POSIX.errno() == POSIX.EINTR continue;
        if written <= 0 { ok = false; break; }
        at += written;
    }
    if ok ok = POSIX.fsync(fd) == 0;
    POSIX.close(fd);
    if ok ok = POSIX.rename(c_tmp, temp_c_string(path)) == 0;
    if !ok { POSIX.unlink(c_tmp); return false; }
    // The rename is an entry in the folder: flush that as well.
    dir := POSIX.open(temp_c_string(path_strip_filename(path)), POSIX.O_RDONLY | POSIX.O_DIRECTORY | POSIX.O_CLOEXEC);
    if dir >= 0 { POSIX.fsync(dir); POSIX.close(dir); }
    return true;
}



platform_sleep_until :: (deadline_seconds: float64) {
    // Coarse sleep, then spin the last stretch for precision.
    while true {
        remaining := deadline_seconds - seconds_since_init();
        if remaining <= 0 break;
        if remaining > 0.002 POSIX.usleep(cast(u32) ((remaining - 0.0015) * 1_000_000));
    }
}

// The font file fontconfig picks for a pattern ("sans-serif",
// "monospace:weight=bold"), as the desktop's other programs would, and the
// face in it. False without fontconfig.
platform_find_font :: (pattern: string) -> path: string, face_index: int, ok: bool {
    if !fontconfig_tried {
        fontconfig_tried = true;
        if dl_load(*fontconfig, .["libfontconfig.so.1"]) fontconfig_config = fontconfig.FcInitLoadConfigAndFonts();
    }
    if !fontconfig_config return "", 0, false;
    query := fontconfig.FcNameParse(temp_c_string(pattern));
    if !query return "", 0, false;
    defer fontconfig.FcPatternDestroy(query);
    fontconfig.FcConfigSubstitute(fontconfig_config, query, FcMatchPattern);
    fontconfig.FcDefaultSubstitute(query);
    result: s32;
    match := fontconfig.FcFontMatch(fontconfig_config, query, *result);
    if !match return "", 0, false;
    defer fontconfig.FcPatternDestroy(match);
    file: *u8;
    index: s32;
    if fontconfig.FcPatternGetString(match, "file", 0, *file) != FcResultMatch return "", 0, false;
    fontconfig.FcPatternGetInteger(match, "index", 0, *index);
    return copy_string(to_string(file),, temp), index, true;
}

// Xft.dpi from the X resources (the RESOURCE_MANAGER property's text), or 0
// when it isn't set. Pure, for the self-test.
parse_xft_dpi :: (resources: string) -> float {
    for line: split(resources, "\n",, temp) {
        found, name, value := split_from_left(line, ":");
        if !found || trim(name) != "Xft.dpi" continue;
        dpi, ok := string_to_float(trim(value));
        if ok && dpi > 0 return cast(float) dpi;
    }
    return 0;
}

// The Key for an X keysym, or UNKNOWN. Pure, for the self-test.
key_from_keysym :: (sym: u64) -> Key {
    if sym >= #char "a" && sym <= #char "z" return cast(Key) (sym - 32);
    if (sym >= #char "A" && sym <= #char "Z") || (sym >= #char "0" && sym <= #char "9") return cast(Key) sym;
    if sym >= XK_F1 && sym <= XK_F1 + 11 return cast(Key) (cast(u64) Key.F1 + sym - XK_F1);
    if sym == {
        case XK_BackSpace;                    return .BACKSPACE;
        case XK_Tab;         #through;
        case XK_ISO_Left_Tab;                 return .TAB;   // Shift+Tab.
        case XK_Return;      #through;
        case XK_KP_Enter;                     return .ENTER;
        case XK_Escape;                       return .ESCAPE;
        case XK_space;                        return .SPACE;
        case XK_Delete;      #through;
        case XK_KP_Delete;                    return .DELETE;
        case XK_Home;        #through;
        case XK_KP_Home;                      return .HOME;
        case XK_End;         #through;
        case XK_KP_End;                       return .END;
        case XK_Page_Up;     #through;
        case XK_KP_Page_Up;                   return .PAGE_UP;
        case XK_Page_Down;   #through;
        case XK_KP_Page_Down;                 return .PAGE_DOWN;
        case XK_Left;        #through;
        case XK_KP_Left;                      return .LEFT;
        case XK_Right;       #through;
        case XK_KP_Right;                     return .RIGHT;
        case XK_Up;          #through;
        case XK_KP_Up;                        return .UP;
        case XK_Down;        #through;
        case XK_KP_Down;                      return .DOWN;
        case XK_Shift_L;     #through;
        case XK_Shift_R;                      return .SHIFT;
        case XK_Control_L;   #through;
        case XK_Control_R;                    return .CONTROL;
        case XK_Alt_L;       #through;
        case XK_Alt_R;       #through;
        case XK_Meta_L;      #through;
        case XK_Meta_R;                       return .ALT;
    }
    return .UNKNOWN;
}

// The letter or digit printed at a key's place on a US keyboard, for
// layouts with no Latin letters there (Cyrillic, Greek...) and digits on
// AZERTY, so Ctrl shortcuts still work. X keycodes are evdev's plus 8.
key_from_keycode :: (keycode: u32) -> Key {
    ROWS :: struct { first: u32; keys: string; }.[
        .{10, "1234567890"},
        .{24, "QWERTYUIOP"},
        .{38, "ASDFGHJKL"},
        .{52, "ZXCVBNM"},
    ];
    for ROWS {
        if keycode >= it.first && keycode < it.first + it.keys.count return cast(Key) it.keys[keycode - it.first];
    }
    return .UNKNOWN;
}

#scope_file

POSIX :: #import "POSIX";
Process_Module :: #import "Process";

app_data_dir: string;

// Child processes.

// Runs a program apart from us (xdg-open, and the browser it starts): a
// grandchild, adopted by init, so it neither becomes a zombie nor ends when
// Uppies does.
spawn_detached :: (args: [] string) -> bool {
    argv := NewArray(args.count + 1, *u8,, temp);
    for args argv[it_index] = temp_c_string(it);
    argv[args.count] = null;
    // Between fork and exec, only calls that are safe there: no allocation.
    pid := POSIX.fork();
    if pid < 0 return false;
    if pid == 0 {
        if POSIX.fork() == 0 {
            POSIX.setsid();
            POSIX.execvp(argv[0], argv.data);
            POSIX._exit(127);
        }
        POSIX._exit(0);
    }
    status: s32;
    while POSIX.waitpid(pid, *status, 0) < 0 && POSIX.errno() == POSIX.EINTR {}
    return true;
}

// Runs a dialog program and returns what it printed. While it runs, X
// events are still handled, so the window repaints its background and the
// window manager sees we are alive, but input goes to the dialog. False if
// it couldn't be run; an empty string when cancelled.
run_dialog :: (args: [] string) -> string, bool {
    process: Process_Module.Process;
    if !Process_Module.create_process(*process, ..args, capture_and_return_output = true) return "", false;
    defer Process_Module.deinit(*process);
    out: String_Builder;
    out.allocator = temp;
    buffer: [4096] u8;
    errors: [4096] u8;
    while !process.output.eof || !process.error.eof {
        ok, out_n, err_n := Process_Module.read_from_process(*process, buffer, errors, timeout_ms = 30);
        if !ok break;
        if out_n append(*out, buffer.data, out_n);
        // What can't wait while the dialog is open (the clipboard, pings,
        // closing) is handled; input is dropped.
        linux_dialog_open = true;
        if linux_window_system == .WAYLAND wayland_pump_events();
        else x11_modal_pump();
        linux_dialog_open = false;
    }
    success, result := Process_Module.get_process_result(*process);
    if !success || result.type != .EXITED || result.exit_code == 127 return "", false;
    if result.exit_code != 0 return "", true;   // Cancelled.
    return builder_to_string(*out,, temp), true;
}


// Where the dialog starts and, without one, where files are saved:
// XDG_DOCUMENTS_DIR from user-dirs.dirs, else ~/Documents, else home.
documents_dir :: () -> string {
    home := to_string(POSIX.getenv("HOME"));
    config := to_string(POSIX.getenv("XDG_CONFIG_HOME"));
    if !config config = tprint("%/.config", home);
    dirs, ok := read_entire_file(tprint("%/user-dirs.dirs", config),, temp);
    if ok {
        for line: split(dirs, "\n",, temp) {
            found, name, value := split_from_left(trim(line), "=");
            if !found || name != "XDG_DOCUMENTS_DIR" continue;
            value = trim(value, "\"");
            value = replace(value, "$HOME", home,, temp);
            if is_directory(value) return value;
        }
    }
    documents := tprint("%/Documents", home);
    if is_directory(documents) return documents;
    return ifx home then home else exe_dir;
}

// suggested_name in folder, with " 2", " 3"... before the extension if taken.
free_path :: (folder: string, suggested_name: string, extension: string) -> string {
    stem := suggested_name;
    if ends_with(to_lower_copy(stem,, temp), tprint(".%", extension)) stem = slice(stem, 0, stem.count - extension.count - 1);
    path := tprint("%/%.%", folder, stem, extension);
    n := 2;
    while file_exists(path) {
        path = tprint("%/% %.%", folder, stem, n, extension);
        n += 1;
    }
    return path;
}

// The program's full path, searched for on the PATH; empty if it isn't there.
find_program :: (name: string) -> string {
    for dir: split(to_string(POSIX.getenv("PATH")), ":",, temp) {
        if !dir continue;
        candidate := tprint("%/%", dir, name);
        if file_exists(candidate) return candidate;
    }
    return "";
}

make_private_directory :: (path: string) {
    make_directory_if_it_does_not_exist(path, recursive = true);
    if POSIX.chmod(temp_c_string(path), POSIX.S_IRWXU) != 0 {
        // The files in it are 0600 anyway (platform_write_file_atomic).
        log_error("Could not make % private to this user.\n", path);
    }
}

// The key behind platform_protect, made on first use and kept for the
// session; the UI thread (the token) and the store writer thread both use
// it. In the Secret Service when the desktop has one, else in local.key.
PROTECT_MAGIC  :: "UPK1";
PROTECT_HEADER :: PROTECT_MAGIC.count + AES_NONCE_SIZE;   // Then the ciphertext, then the tag.
SECRET_SCHEMA_NAME :: "au.net.ruben.uppies.LocalKey";
SECRET_LABEL       :: "Uppies local encryption key";

protect_key:    [AES_KEY_SIZE] u8;
protect_loaded: bool;
protect_failed: bool;   // Refused once: don't ask again this session.
protect_mutex:  POSIX.pthread_mutex_t;   // Zero is PTHREAD_MUTEX_INITIALIZER on glibc.

Key_Store :: enum u8 { KEYRING; FILE; }

// Which store the key is in (or will be): local.key while it exists, so data
// never splits between two keys (key_file_migrate moves it to the keyring
// when it can); else the keyring when libsecret is installed. Whether a
// session bus is there is libsecret's to find out (DBUS_SESSION_BUS_ADDRESS,
// or $XDG_RUNTIME_DIR/bus without it). Sets what the UI calls it.
protect_choose_store :: () -> Key_Store {
    store := Key_Store.FILE;
    if !file_exists(key_file_path()) && secret_load() store = .KEYRING;
    if store == .FILE {
        PLATFORM_SECRET_STORE = "a key file only you can read";
        PLATFORM_TOKEN_STORED = "Encrypted with a key in a file only you can read";
    } else {
        PLATFORM_SECRET_STORE = "your login keyring";
        PLATFORM_TOKEN_STORED = "Encrypted with a key in your login keyring";
    }
    return store;
}

protect_load_key :: () -> bool {
    POSIX.pthread_mutex_lock(*protect_mutex);
    defer POSIX.pthread_mutex_unlock(*protect_mutex);
    if protect_loaded return true;
    if protect_failed return false;

    ok := false;
    if protect_choose_store() == .KEYRING {
        found, error := keyring_read(*protect_key);
        if found {
            ok = true;
        } else if !error {
            ok = make_key(*protect_key, keyring_store);
        } else if !anything_sealed() {
            // A keyring that is there but doesn't work (no session bus, no
            // Secret Service running behind it yet): a key file, while
            // nothing needs the keyring's key, until key_file_migrate can
            // move it.
            log("The keyring is not available (%); keeping the key in a file.\n", error);
            ok = key_file_load(*protect_key);
            protect_choose_store();
        } else {
            log_error("The keyring did not give Uppies its key: %\n", error);
        }
    } else {
        ok = key_file_load(*protect_key);
        if ok key_file_migrate(*protect_key);
    }
    if !ok {
        memset(protect_key.data, 0, protect_key.count);
        protect_failed = true;
        return false;
    }
    protect_loaded = true;
    return true;
}

// A new key, stored with `store`, but never while something sealed with an
// old one is still there: that would lock it away for good.
make_key :: (key: *[AES_KEY_SIZE] u8, store: (key: *[AES_KEY_SIZE] u8) -> bool) -> bool {
    if anything_sealed() {
        log_error("Uppies' key is missing, but data sealed with it is still in %. Delete that folder to start again.\n", platform_app_data_dir());
        return false;
    }
    if !platform_random_bytes(key.*) return false;
    return store(key);
}

anything_sealed :: () -> bool {
    for string.["token.bin", "store.uppies", "user.bin"] {
        if file_exists(tprint("%/%", platform_app_data_dir(), it)) return true;
    }
    return false;
}

key_file_path :: () -> string { return tprint("%/local.key", platform_app_data_dir()); }

// The key in local.key beside the data it protects, readable only by this
// user (0600). Weaker than a keyring: anything running as this user can
// read the file.
key_file_load :: (key: *[AES_KEY_SIZE] u8) -> bool {
    path := key_file_path();
    data, ok := read_entire_file(path,, temp);
    defer if data.count memset(data.data, 0, data.count);   // Don't leave the key in temporary storage.
    if ok {
        // Never replace a key file we couldn't use.
        if data.count != AES_KEY_SIZE return false;
        memcpy(key.data, data.data, AES_KEY_SIZE);
        return true;
    }
    if file_exists(path) return false;
    return make_key(key, (key: *[AES_KEY_SIZE] u8) -> bool { return platform_write_file_atomic(key_file_path(), key.*); });
}

// A key that went to local.key because there was no keyring then (no
// session bus yet, a keyring not yet running) moves into the keyring once
// there is one. It is the same key, so nothing sealed with it changes. Never
// over a different key already in the keyring: that one may seal another
// data folder (-data-dir). Anything short of a key read back intact leaves
// local.key as it was, to try again next time.
key_file_migrate :: (key: *[AES_KEY_SIZE] u8) {
    if !secret_load() return;
    stored: [AES_KEY_SIZE] u8;
    defer memset(stored.data, 0, stored.count);
    found, error := keyring_read(*stored);
    if error return;   // No keyring to move to (yet).
    if found {
        // Ours already, from a move that stopped before removing the file.
        if memcmp(stored.data, key.data, AES_KEY_SIZE) != 0 return;
    } else {
        if !keyring_store(key) return;
        found, error = keyring_read(*stored);
        if !found || memcmp(stored.data, key.data, AES_KEY_SIZE) != 0 return;
    }

    // Unlinked first, then overwritten through the open file: a failure
    // in between can't leave a zeroed key file where the key used to be.
    path := temp_c_string(key_file_path());
    fd := POSIX.open(path, POSIX.O_WRONLY | POSIX.O_CLOEXEC);
    if POSIX.unlink(path) != 0 {
        if fd >= 0 POSIX.close(fd);
        return;
    }
    if fd >= 0 {
        zeros: [AES_KEY_SIZE] u8;
        POSIX.write(fd, zeros.data, AES_KEY_SIZE);
        POSIX.fsync(fd);
        POSIX.close(fd);
    }
    log("Moved Uppies' key from local.key into your login keyring.\n");
    protect_choose_store();
}

// The Secret Service through libsecret. The key is stored as hex: secrets
// there are text.

SecretSchemaAttribute :: struct {
    name: *u8;
    type: s32;   // SECRET_SCHEMA_ATTRIBUTE_STRING = 0.
}

SecretSchema :: struct {
    name:  *u8;
    flags: s32;
    attributes: [32] SecretSchemaAttribute;
    reserved: s32;
    reserved1, reserved2, reserved3, reserved4, reserved5, reserved6, reserved7: *void;
}

GError :: struct {
    domain:  u32;
    code:    s32;
    message: *u8;
}

Libsecret :: struct {
    secret_password_lookupv_sync: (schema: *SecretSchema, attributes: *void, cancellable: *void, error: **GError) -> *u8 #c_call;
    secret_password_storev_sync:  (schema: *SecretSchema, attributes: *void, collection: *u8, label: *u8, password: *u8, cancellable: *void, error: **GError) -> s32 #c_call;
    secret_password_free:         (password: *u8) #c_call;
}

Glib :: struct {
    g_hash_table_new:    (hash: *void, equal: *void) -> *void #c_call;
    g_hash_table_insert: (table: *void, key: *void, value: *void) -> s32 #c_call;
    g_hash_table_unref:  (table: *void) #c_call;
    g_error_free:        (error: *GError) #c_call;
    g_str_hash:          (key: *void) -> u32 #c_call;
    g_str_equal:         (a: *void, b: *void) -> s32 #c_call;
}

libsecret: Libsecret;
glib: Glib;
secret_tried, secret_ok: bool;

secret_load :: () -> bool {
    if !secret_tried {
        secret_tried = true;
        secret_ok = dl_load(*libsecret, .["libsecret-1.so.0"]) && dl_load(*glib, .["libglib-2.0.so.0"]);
    }
    return secret_ok;
}

secret_schema :: () -> SecretSchema {
    schema: SecretSchema;
    schema.name = SECRET_SCHEMA_NAME;
    schema.attributes[0] = .{"application", 0};
    schema.attributes[1] = .{"purpose", 0};
    return schema;
}

secret_attributes :: () -> *void {
    table := glib.g_hash_table_new(cast(*void) glib.g_str_hash, cast(*void) glib.g_str_equal);
    glib.g_hash_table_insert(table, "application".data, "uppies".data);
    glib.g_hash_table_insert(table, "purpose".data, "local-key".data);
    return table;
}

// found: the key was there and is now in `key`. error: why the keyring
// couldn't be asked (temporary storage); neither means it has no key yet.
keyring_read :: (key: *[AES_KEY_SIZE] u8) -> found: bool, error: string {
    schema := secret_schema();
    attributes := secret_attributes();
    defer glib.g_hash_table_unref(attributes);
    error: *GError;
    secret := libsecret.secret_password_lookupv_sync(*schema, attributes, null, *error);
    if error {
        defer glib.g_error_free(error);
        return false, copy_string(to_string(error.message),, temp);
    }
    if !secret return false, "";
    defer libsecret.secret_password_free(secret);
    hex := to_string(secret);
    if hex.count != AES_KEY_SIZE * 2 return false, "the stored key is not one Uppies made";
    for 0..AES_KEY_SIZE - 1 {
        hi, lo := hex_digit(hex[it * 2]), hex_digit(hex[it * 2 + 1]);
        if hi < 0 || lo < 0 return false, "the stored key is not one Uppies made";
        key.*[it] = cast(u8) (hi * 16 + lo);
    }
    return true, "";
}

keyring_store :: (key: *[AES_KEY_SIZE] u8) -> bool {
    schema := secret_schema();
    attributes := secret_attributes();
    defer glib.g_hash_table_unref(attributes);
    hex: [AES_KEY_SIZE * 2 + 1] u8;
    DIGITS :: "0123456789abcdef";
    for key.* { hex[it_index * 2] = DIGITS[it >> 4]; hex[it_index * 2 + 1] = DIGITS[it & 0xF]; }
    defer memset(hex.data, 0, hex.count);
    error: *GError;
    stored := libsecret.secret_password_storev_sync(*schema, attributes, null, SECRET_LABEL, hex.data, null, *error);
    if error {
        log_error("Could not store Uppies' key in the keyring: %\n", to_string(error.message));
        glib.g_error_free(error);
        return false;
    }
    return stored != 0;
}

hex_digit :: (c: u8) -> int {
    if c >= #char "0" && c <= #char "9" return c - #char "0";
    if c >= #char "a" && c <= #char "f" return c - #char "a" + 10;
    if c >= #char "A" && c <= #char "F" return c - #char "A" + 10;
    return -1;
}

// The aad of a sealed secret: the app's name and the caller's entropy.
protect_aad :: (entropy: string) -> string { return tprint("Uppies%", entropy); }

as_bytes :: (s: string) -> [] u8 {
    b: [] u8;
    b.data, b.count = s.data, s.count;
    return b;
}

// OpenSSL's libcrypto: AES-256-GCM. Version 3, or 1.1 on older systems;
// these calls are the same in both.
Libcrypto :: struct {
    EVP_CIPHER_CTX_new:  () -> *void #c_call;
    EVP_CIPHER_CTX_free: (ctx: *void) #c_call;
    EVP_CIPHER_CTX_ctrl: (ctx: *void, type: s32, arg: s32, ptr: *void) -> s32 #c_call;
    EVP_aes_256_gcm:     () -> *void #c_call;
    EVP_EncryptInit_ex:  (ctx: *void, cipher: *void, engine: *void, key: *u8, iv: *u8) -> s32 #c_call;
    EVP_EncryptUpdate:   (ctx: *void, out: *u8, out_length: *s32, in: *u8, in_length: s32) -> s32 #c_call;
    EVP_EncryptFinal_ex: (ctx: *void, out: *u8, out_length: *s32) -> s32 #c_call;
    EVP_DecryptInit_ex:  (ctx: *void, cipher: *void, engine: *void, key: *u8, iv: *u8) -> s32 #c_call;
    EVP_DecryptUpdate:   (ctx: *void, out: *u8, out_length: *s32, in: *u8, in_length: s32) -> s32 #c_call;
    EVP_DecryptFinal_ex: (ctx: *void, out: *u8, out_length: *s32) -> s32 #c_call;
}
crypto: Libcrypto;
crypto_tried, crypto_ok: bool;
crypto_mutex: POSIX.pthread_mutex_t;

EVP_CTRL_GCM_SET_IVLEN :: 0x9;
EVP_CTRL_GCM_GET_TAG   :: 0x10;
EVP_CTRL_GCM_SET_TAG   :: 0x11;

crypto_load :: () -> bool {
    POSIX.pthread_mutex_lock(*crypto_mutex);
    defer POSIX.pthread_mutex_unlock(*crypto_mutex);
    if !crypto_tried {
        crypto_tried = true;
        crypto_ok = dl_load(*crypto, .["libcrypto.so.3", "libcrypto.so.1.1"]);
        if !crypto_ok log_error("OpenSSL (libcrypto) is not installed: Uppies can't keep your token or data encrypted.\n");
    }
    return crypto_ok;
}

// fontconfig: which font file the desktop means by a name.
Fontconfig :: struct {
    FcInitLoadConfigAndFonts: () -> *void #c_call;
    FcNameParse:          (name: *u8) -> *void #c_call;
    FcConfigSubstitute:   (config: *void, pattern: *void, kind: s32) -> s32 #c_call;
    FcDefaultSubstitute:  (pattern: *void) #c_call;
    FcFontMatch:          (config: *void, pattern: *void, result: *s32) -> *void #c_call;
    FcPatternGetString:   (pattern: *void, object: *u8, n: s32, value: **u8) -> s32 #c_call;
    FcPatternGetInteger:  (pattern: *void, object: *u8, n: s32, value: *s32) -> s32 #c_call;
    FcPatternDestroy:     (pattern: *void) #c_call;
}
fontconfig: Fontconfig;
fontconfig_tried: bool;
fontconfig_config: *void;
FcMatchPattern :: 0;
FcResultMatch  :: 0;

// Bindings the X11 and POSIX modules don't have.
libc   :: #library,system "libc";
getrandom :: (buffer: *void, length: u64, flags: u32) -> s64 #foreign libc;
setlocale :: (category: s32, locale: *u8) -> *u8 #foreign libc;
LC_CTYPE :: 0;   // glibc's.


XK_F1           :: 0xffbe;
XK_BackSpace    :: 0xff08;
XK_Tab          :: 0xff09;
XK_ISO_Left_Tab :: 0xfe20;
XK_Return       :: 0xff0d;
XK_KP_Enter     :: 0xff8d;
XK_Escape       :: 0xff1b;
XK_space        :: 0x0020;
XK_Delete       :: 0xffff;
XK_KP_Delete    :: 0xff9f;
XK_Home         :: 0xff50;
XK_Left         :: 0xff51;
XK_Up           :: 0xff52;
XK_Right        :: 0xff53;
XK_Down         :: 0xff54;
XK_Page_Up      :: 0xff55;
XK_Page_Down    :: 0xff56;
XK_End          :: 0xff57;
XK_KP_Home      :: 0xff95;
XK_KP_Left      :: 0xff96;
XK_KP_Up        :: 0xff97;
XK_KP_Right     :: 0xff98;
XK_KP_Down      :: 0xff99;
XK_KP_Page_Up   :: 0xff9a;
XK_KP_Page_Down :: 0xff9b;
XK_KP_End       :: 0xff9c;
XK_Shift_L      :: 0xffe1;
XK_Shift_R      :: 0xffe2;
XK_Control_L    :: 0xffe3;
XK_Control_R    :: 0xffe4;
XK_Meta_L       :: 0xffe7;
XK_Meta_R       :: 0xffe8;
XK_Alt_L        :: 0xffe9;
XK_Alt_R        :: 0xffea;
