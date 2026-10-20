// X11 implementation of the platform layer (Xlib). On a Wayland desktop it
// runs through XWayland; a native Wayland layer can come later.
//
// - One window, drawn only by the Vulkan backend (render/vulkan). Vulkan's
//   window system code talks to the X server over a connection of its own
//   (platform_x11_vk_display), so its threads never read the events of the
//   one the main loop waits on.
// - Sizes are physical pixels like everywhere else. The scale is Xft.dpi /
//   96 (what the desktop's display settings set; 1.5 at 144 DPI), or
//   UPPIES_SCALE when set, and follows changes made while running.
// - The main loop sleeps in poll() on the X connection and an eventfd that
//   platform_wake writes from any thread (Xlib is only ever called from the
//   main thread).
// - X has no modal loop: a window being dragged or resized keeps sending
//   events to the main loop, so platform.modal_frame is never needed.
// - Until the first frame is drawn, the window shows a background color
//   close to the theme's (platform_set_dark_appearance), so it never flashes
//   white.
//
// - Secrets at rest (the token, the store file's key) are sealed with
//   AES-256-GCM (OpenSSL) under a key kept in the desktop's keyring (the
//   Secret Service: GNOME Keyring, KWallet), the counterpart of DPAPI and the
//   macOS Keychain; without a keyring, in a file only this user can read.
//
// Libraries other than libc and libX11 are loaded at run time (linux_dl.jai).

#load "linux_dl.jai";

// For the Vulkan backend: a Display* and the window, as Vulkan's Xlib surface
// takes them.
platform_x11_vk_display: *void;
platform_x11_window: u64;

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

platform_init :: (title: string, logical_width: int, logical_height: int) -> bool {
    linux_context = context;

    // Input methods compose text in the user's locale.
    setlocale(LC_CTYPE, "");
    if !X.XSupportsLocale() setlocale(LC_CTYPE, "C.UTF-8");
    X.XSetLocaleModifiers("");

    X.XInitThreads();   // The Vulkan driver uses its connection from threads of its own.
    display = X.XOpenDisplay(null);
    if !display {
        log_error("Could not connect to the X server (DISPLAY is \"%\"). Uppies needs an X11 or XWayland session.\n", to_string(POSIX.getenv("DISPLAY")));
        return false;
    }
    platform_x11_vk_display = X.XOpenDisplay(null);
    if !platform_x11_vk_display platform_x11_vk_display = display;
    X.XSetErrorHandler(on_x_error);
    X.XSetIOErrorHandler(on_x_io_error);

    screen = X.XDefaultScreen(display);
    root   = X.XRootWindow(display, screen);
    intern_atoms();

    update_scale();

    // Logical size scaled, fit to the work area (the screen less panels),
    // centered in it.
    area := work_area();
    w := min(cast(s32) (logical_width  * platform.dpi_scale + 0.5), area.width);
    h := min(cast(s32) (logical_height * platform.dpi_scale + 0.5), area.height - cast(s32) (32 * platform.dpi_scale));   // Title bar.
    x := area.x + (area.width - w) / 2;
    y := area.y + (area.height - h) / 2;

    attributes: X.XSetWindowAttributes;
    attributes.background_pixel = background_pixel(dark_background);
    attributes.bit_gravity      = NorthWestGravity;   // Resizing keeps the content where it is until the next frame.
    attributes.event_mask = X.KeyPressMask | X.KeyReleaseMask | X.ButtonPressMask | X.ButtonReleaseMask | X.PointerMotionMask
                          | X.EnterWindowMask | X.LeaveWindowMask | X.ExposureMask | X.StructureNotifyMask | X.FocusChangeMask
                          | X.PropertyChangeMask;
    mask: u64 = CWBackPixel | CWBitGravity | X.CWEventMask;
    window = X.XCreateWindow(display, root, x, y, xx w, xx h, 0, X.CopyFromParent, X.InputOutput, null, mask, *attributes);
    if !window {
        log_error("Could not create the window.\n");
        return false;
    }
    platform_x11_window = window;

    protocols := X.Atom.[atoms.WM_DELETE_WINDOW, atoms._NET_WM_PING];
    X.XSetWMProtocols(display, window, protocols.data, protocols.count);
    set_title(title);

    // WM_CLASS ties the window to the desktop entry (StartupWMClass=Uppies).
    class_hint: X.XClassHint;
    class_hint.res_name  = "uppies";
    class_hint.res_class = "Uppies";
    X.XSetClassHint(display, window, *class_hint);

    hints: X.XSizeHints;
    hints.flags = X.PPosition;
    hints.x, hints.y = x, y;
    X.XSetWMNormalHints(display, window, *hints);
    update_size_hints();

    pid := cast(s64) POSIX.getpid();
    set_property(atoms._NET_WM_PID, X.XA_CARDINAL, 32, *pid, 1);
    host: [256] u8;
    if POSIX.gethostname(host.data, host.count - 1) == 0 {
        set_property(atoms.WM_CLIENT_MACHINE, X.XA_STRING, 8, host.data, c_style_strlen(host.data));
    }
    window_type := cast(s64) atoms._NET_WM_WINDOW_TYPE_NORMAL;
    set_property(atoms._NET_WM_WINDOW_TYPE, X.XA_ATOM, 32, *window_type, 1);
    set_window_icon();
    set_theme_variant();

    // Launched from a desktop entry: the launcher's startup notification ends
    // when this window maps. Children (xdg-open) mustn't inherit it.
    startup_id := to_string(POSIX.getenv("DESKTOP_STARTUP_ID"));
    if startup_id {
        set_property(atoms._NET_STARTUP_ID, atoms.UTF8_STRING, 8, startup_id.data, startup_id.count);
        POSIX.unsetenv("DESKTOP_STARTUP_ID");
    }

    // Text input through the input method (dead keys, compose, IMEs).
    input_method = X.XOpenIM(display, null, null, null);
    if input_method {
        input_context = X.XCreateIC(input_method, X.XNInputStyle, X.XIMPreeditNothing | X.XIMStatusNothing,
                                    X.XNClientWindow, window, X.XNFocusWindow, window, null);
    }
    if !input_context log("No X input method; typing composes no characters.\n");

    // Held keys repeat as presses with a single release at the end, as on
    // Windows and macOS, instead of release-press pairs.
    supported: s32;
    XkbSetDetectableAutoRepeat(display, X.True, *supported);

    cursors[Cursor.ARROW] = X.XCreateFontCursor(display, XC_left_ptr);
    cursors[Cursor.HAND]  = X.XCreateFontCursor(display, XC_hand2);
    cursors[Cursor.TEXT]  = X.XCreateFontCursor(display, XC_xterm);
    X.XDefineCursor(display, window, cursors[Cursor.ARROW]);

    // Xft.dpi lives on the root window: hear when the display settings change it.
    X.XSelectInput(display, root, X.PropertyChangeMask);

    wake_fd = POSIX.eventfd(0, xx ((cast(u32) POSIX.EFD.CLOEXEC) | (cast(u32) POSIX.EFD.NONBLOCK)));
    if wake_fd < 0 {
        log_error("Could not create an eventfd.\n");
        return false;
    }

    randr_init();
    platform.width, platform.height = w, h;
    update_refresh_rate(x + w / 2, y + h / 2);
    protect_choose_store();
    X.XFlush(display);
    return true;
}

// Called once the first frame has been rendered.
platform_show_window :: () {
    if !window return;
    X.XMapRaised(display, window);
    X.XFlush(display);
}

// The window's title bar and the background shown before the first frame,
// dark or light to match the theme. The title bar follows window managers
// that read GTK's hint (Mutter, Xfwm); the rest draw their own theme.
platform_set_dark_appearance :: (dark: bool) {
    dark_background = dark;
    if !window return;
    X.XSetWindowBackground(display, window, background_pixel(dark));
    set_theme_variant();
}

platform_shutdown :: () {
    if !display return;
    clipboard_hand_over();
    if input_context X.XDestroyIC(input_context);
    if input_method  X.XCloseIM(input_method);
    for cursors if it X.XFreeCursor(display, it);
    if window X.XDestroyWindow(display, window);
    if platform_x11_vk_display && platform_x11_vk_display != display X.XCloseDisplay(platform_x11_vk_display);
    X.XCloseDisplay(display);
    if wake_fd >= 0 POSIX.close(wake_fd);
    display, window, input_method, input_context = null, 0, null, null;
    platform_x11_vk_display, platform_x11_window = null, 0;
    wake_fd = -1;
}

// Handles every pending event without blocking.
platform_pump_events :: () {
    if !display return;
    while X.XPending(display) > 0 {
        event: X.XEvent;
        X.XNextEvent(display, *event);
        // The input method takes the keys it composes with (dead keys).
        if X.XFilterEvent(*event, X.None) continue;
        dispatch_event(*event);
    }
}

// Sleeps until the OS has an event for us, or until timeout_seconds pass
// (negative: no timeout). An idle app costs nothing.
platform_wait_for_events :: (timeout_seconds: float64 = -1) {
    if !display return;
    if X.XPending(display) > 0 return;   // Also sends what we have queued for the server.
    fds: [2] POSIX.pollfd;
    fds[0].fd, fds[0].events = X.XConnectionNumber(display), POSIX.POLLIN;
    fds[1].fd, fds[1].events = wake_fd, POSIX.POLLIN;
    ms: s32 = -1;
    if timeout_seconds >= 0 ms = cast(s32) min(ceil(timeout_seconds * 1000), 1_000_000_000.0);
    POSIX.poll(fds.data, fds.count, ms);
    if fds[1].revents & POSIX.POLLIN {
        count: u64;
        POSIX.read(wake_fd, *count, size_of(u64));
        platform.needs_redraw = true;
    }
}

// Wakes the main loop from any thread (a network reply arrived).
platform_wake :: () {
    if wake_fd < 0 return;
    one: u64 = 1;
    POSIX.write(wake_fd, *one, size_of(u64));
}

// Opens a web address in the browser, or a folder in the file manager,
// through xdg-open. Only https addresses and absolute paths are opened.
platform_open_url :: (url: string) {
    if !begins_with(url, "https://") && !begins_with(url, "http://") && !begins_with(url, "/") return;
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

    args: [..] string;
    args.allocator = temp;
    if zenity {
        array_add(*args, zenity, "--file-selection", "--save", "--confirm-overwrite", tprint("--title=%", title),
                  tprint("--filename=%", start), tprint("--file-filter=% | *.%", type_name, extension),
                  tprint("--attach=%", window));
    } else if kdialog {
        array_add(*args, kdialog, "--getsavefilename", start, tprint("% (*.%)", type_name, extension),
                  "--title", title, "--attach", tprint("%", window));
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

platform_clipboard_get :: () -> string {   // Temporary storage.
    if !display return "";
    if clipboard.owned return copy_string(clipboard.text,, temp);
    if X.XGetSelectionOwner(display, atoms.CLIPBOARD) == X.None return "";
    text, ok := clipboard_request(atoms.UTF8_STRING);
    if !ok text = clipboard_request(X.XA_STRING);   // An old program: Latin-1.
    return text;
}

platform_clipboard_set :: (text: string) {
    if !display return;
    free(clipboard.text);
    clipboard.text = copy_string(text);
    X.XSetSelectionOwner(display, atoms.CLIPBOARD, window, last_event_time);
    clipboard.owned = X.XGetSelectionOwner(display, atoms.CLIPBOARD) == window;
    if !clipboard.owned log_error("Could not take the clipboard.\n");
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

platform_set_cursor :: (cursor: Cursor) {
    if cursor == current_cursor return;
    current_cursor = cursor;
    if window X.XDefineCursor(display, window, cursors[cursor]);
}

platform_set_title :: (title: string) {
    if window set_title(title);
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

X     :: #import "X11";
POSIX :: #import "POSIX";
Process_Module :: #import "Process";

linux_context: #Context;
display: *X.Display;
screen: s32;
root: X.Window;
window: X.Window;
input_method: X.XIM;
input_context: X.XIC;
wake_fd: s32 = -1;
app_data_dir: string;
current_cursor: Cursor;
cursors: [#run enum_highest_value(Cursor) + 1] X.Cursor;
dark_background := true;
last_event_time: X.Time;   // For the clipboard, which X orders by time.
mapped: bool;
scale_override: float;     // UPPIES_SCALE, if set.

Atoms :: struct {
    WM_PROTOCOLS: X.Atom;
    WM_DELETE_WINDOW: X.Atom;
    WM_CLIENT_MACHINE: X.Atom;
    _NET_WM_PING: X.Atom;
    _NET_WM_NAME: X.Atom;
    _NET_WM_ICON_NAME: X.Atom;
    _NET_WM_PID: X.Atom;
    _NET_WM_ICON: X.Atom;
    _NET_WM_WINDOW_TYPE: X.Atom;
    _NET_WM_WINDOW_TYPE_NORMAL: X.Atom;
    _NET_WM_STATE: X.Atom;
    _NET_WM_STATE_HIDDEN: X.Atom;
    _NET_WORKAREA: X.Atom;
    _NET_STARTUP_ID: X.Atom;
    _GTK_THEME_VARIANT: X.Atom;
    UTF8_STRING: X.Atom;
    CLIPBOARD: X.Atom;
    TARGETS: X.Atom;
    TEXT: X.Atom;
    INCR: X.Atom;
    RESOURCE_MANAGER: X.Atom;
    UPPIES_SELECTION: X.Atom;   // Where pasted text is delivered to us.
}
atoms: Atoms;

intern_atoms :: () {
    info := type_info(Atoms);
    names: [..] *u8;
    names.allocator = temp;
    for info.members array_add(*names, temp_c_string(it.name));
    X.XInternAtoms(display, names.data, xx names.count, X.False, cast(*X.Atom) *atoms);
}

set_property :: (property: X.Atom, type: X.Atom, format: s32, data: *void, count: int) {
    X.XChangeProperty(display, window, property, type, format, X.PropModeReplace, data, xx count);
}

set_title :: (title: string) {
    X.XStoreName(display, window, temp_c_string(title));   // Latin-1 fallback for old window managers.
    set_property(atoms._NET_WM_NAME, atoms.UTF8_STRING, 8, title.data, title.count);
    set_property(atoms._NET_WM_ICON_NAME, atoms.UTF8_STRING, 8, title.data, title.count);
}

// The minimum size, in pixels at the current scale.
update_size_hints :: () {
    hints: X.XSizeHints;
    hints.flags = X.PMinSize;
    hints.min_width  = cast(s32) (MIN_WINDOW_WIDTH  * platform.dpi_scale + 0.5);
    hints.min_height = cast(s32) (MIN_WINDOW_HEIGHT * platform.dpi_scale + 0.5);
    X.XSetWMNormalHints(display, window, *hints);
}

// The icon at several sizes, embedded by build.jai: width, height, pixels.
// Format-32 properties are C longs, 64 bits here.
set_window_icon :: () {
    data := NewArray(app_icon_pixels.count, s64,, temp);
    for app_icon_pixels data[it_index] = cast(s64) it;
    set_property(atoms._NET_WM_ICON, X.XA_CARDINAL, 32, data.data, data.count);
}

set_theme_variant :: () {
    variant := ifx dark_background then "dark" else "light";
    set_property(atoms._GTK_THEME_VARIANT, atoms.UTF8_STRING, 8, variant.data, variant.count);
}

// The default themes' backgrounds (Uppies Dark, Uppies Light), as a pixel of
// the default 24-bit TrueColor visual.
background_pixel :: (dark: bool) -> u64 {
    return cast(u64) ifx dark then 0x0B0D10 else 0xECEEF2;
}

Rect_Area :: struct { x, y, width, height: s32; }

// The desktop's work area (the screen less panels and docks), or the screen.
work_area :: () -> Rect_Area {
    area := Rect_Area.{0, 0, X.XDisplayWidth(display, screen), X.XDisplayHeight(display, screen)};
    type: X.Atom;
    format: s32;
    count, after: u64;
    data: *u8;
    if X.XGetWindowProperty(display, root, atoms._NET_WORKAREA, 0, 4, X.False, X.XA_CARDINAL, *type, *format, *count, *after, *data) == X.Success && data {
        if type == X.XA_CARDINAL && format == 32 && count >= 4 {
            v := cast(*s64) data;
            if v[2] > 0 && v[3] > 0 area = .{xx v[0], xx v[1], xx v[2], xx v[3]};
        }
        X.XFree(data);
    }
    return area;
}

// Errors from requests that refer to something gone (a window that asked
// for the clipboard and closed) are harmless; Xlib's default handler would
// end the process over them.
on_x_error :: (d: *X.Display, event: *X.XErrorEvent) -> s32 #c_call {
    push_context linux_context {
        text: [256] u8;
        X.XGetErrorText(d, event.error_code, text.data, text.count);
        log_error("X error: % (request %.%)\n", to_string(text.data), event.request_code, event.minor_code);
    }
    return 0;
}

// The connection to the X server is gone (it quit, or the session ended):
// Xlib exits when this returns.
on_x_io_error :: (d: *X.Display) -> s32 #c_call {
    push_context linux_context { log_error("Lost the connection to the X server.\n"); }
    return 0;
}

dispatch_event :: (event: *X.XEvent) {
    if event.type == {
        case X.KeyPress;
            last_event_time = event.xkey.time;
            on_key(*event.xkey, true);

        case X.KeyRelease;
            last_event_time = event.xkey.time;
            on_key(*event.xkey, false);

        case X.ButtonPress;
            last_event_time = event.xbutton.time;
            on_button(*event.xbutton, true);

        case X.ButtonRelease;
            last_event_time = event.xbutton.time;
            on_button(*event.xbutton, false);

        case X.MotionNotify;
            last_event_time = event.xmotion.time;
            sync_modifiers(event.xmotion.state, .UNKNOWN);
            if !input.synthetic input_on_mouse_move(xx event.xmotion.x, xx event.xmotion.y);

        case X.EnterNotify;
            last_event_time = event.xcrossing.time;
            if !input.synthetic input_on_mouse_move(xx event.xcrossing.x, xx event.xcrossing.y);

        case X.LeaveNotify;
            last_event_time = event.xcrossing.time;
            if input.synthetic return;
            // A drag that leaves the window keeps its mouse until released.
            if input.mouse_down[0] || input.mouse_down[1] || input.mouse_down[2] return;
            input_on_mouse_leave();

        case X.FocusIn;
            if event.xfocus.mode == NotifyUngrab return;   // A keyboard grab (a shortcut of the window manager) ended.
            platform.has_focus = true;
            platform.needs_redraw = true;
            if input_context X.XSetICFocus(input_context);

        case X.FocusOut;
            // Keys released while someone else has the keyboard never reach
            // us, whether focus moved on or a grab began.
            input_release_all();
            if event.xfocus.mode == NotifyGrab return;
            platform.has_focus = false;
            if input_context X.XUnsetICFocus(input_context);

        case X.Expose;
            platform.needs_redraw = true;

        case X.ConfigureNotify;
            c := *event.xconfigure;
            if c.window != window return;
            if c.width != platform.width || c.height != platform.height {
                platform.width, platform.height = c.width, c.height;
                platform.needs_redraw = true;
            }
            // Moved, perhaps to another monitor. Only synthetic events (from
            // the window manager) are in root coordinates.
            if c.send_event update_refresh_rate(c.x + c.width / 2, c.y + c.height / 2);

        case X.MapNotify;
            if event.xmap.window != window return;
            mapped = true;
            platform.minimized = false;
            platform.needs_redraw = true;

        case X.UnmapNotify;
            if event.xunmap.window != window return;
            mapped = false;
            platform.minimized = true;

        case X.PropertyNotify;
            p := *event.xproperty;
            last_event_time = p.time;
            if p.window == root && p.atom == atoms.RESOURCE_MANAGER {
                old := platform.dpi_scale;
                update_scale();
                if platform.dpi_scale != old on_scale_changed(old);
            } else if p.window == window && p.atom == atoms._NET_WM_STATE {
                hidden := window_is_hidden();
                if hidden != platform.minimized {
                    platform.minimized = hidden || !mapped;
                    platform.needs_redraw = true;
                }
            }

        case X.ClientMessage;
            m := *event.xclient;
            if m.message_type != atoms.WM_PROTOCOLS return;
            protocol := cast(X.Atom) m.data.l[0];
            if protocol == atoms.WM_DELETE_WINDOW {
                platform.quit_requested = true;
            } else if protocol == atoms._NET_WM_PING {
                // Still answering: the window manager won't offer to kill us.
                reply := event.*;
                reply.xclient.window = root;
                X.XSendEvent(display, root, X.False, X.SubstructureNotifyMask | X.SubstructureRedirectMask, *reply);
            }

        case X.SelectionRequest;
            clipboard_answer(*event.xselectionrequest);

        case X.SelectionClear;
            if event.xselectionclear.selection == atoms.CLIPBOARD {
                clipboard.owned = false;
                free(clipboard.text);
                clipboard.text = "";
            }

        case;
            if randr.loaded && event.type == randr.event_base + RRScreenChangeNotify {
                randr_load_monitors();
                update_refresh_rate(-1, -1);
            }
    }
}

on_key :: (event: *X.XKeyEvent, down: bool) {
    key := key_of(event);
    if key != .SHIFT && key != .CONTROL && key != .ALT sync_modifiers(event.state, key);
    if key != .UNKNOWN input_on_key(xx key, down);
    if !down return;
    platform.needs_redraw = true;

    // With Ctrl or Alt held it's a shortcut, not text.
    if event.state & (X.ControlMask | X.Mod1Mask) return;
    buffer: [64] u8;
    text: string;
    if input_context {
        status: s32;
        n := X.Xutf8LookupString(input_context, event, buffer.data, buffer.count, null, *status);
        if status == X.XBufferOverflow {
            big := NewArray(n + 1, u8,, temp);
            n = X.Xutf8LookupString(input_context, event, big.data, xx big.count, null, *status);
            text = to_string(big.data, n);
        } else if status == X.XLookupChars || status == X.XLookupBoth {
            text = to_string(buffer.data, n);
        }
    } else {
        n := X.XLookupString(event, buffer.data, buffer.count, null, null);
        text = latin1_to_utf8(to_string(buffer.data, n));
    }
    i := 0;
    while i < text.count {
        cp := next_code_point(text, *i);
        if cp < 32 || cp == 127 continue;   // Control characters.
        array_add(*input.text, cp);
    }
}

// The key pressed: by its keysym in the first layout that has a Latin one
// there, else by its place on the keyboard.
key_of :: (event: *X.XKeyEvent) -> Key {
    key := key_from_keysym(X.XLookupKeysym(event, 0));
    if key != .UNKNOWN return key;
    for group: 0..3 {
        key = key_from_keysym(X.XkbKeycodeToKeysym(display, cast(u8) event.keycode, xx group, 0));
        if key != .UNKNOWN return key;
    }
    return key_from_keycode(event.keycode);
}

// A modifier pressed or released while another window had the keyboard
// never told us: the state that comes with every event says what is held.
sync_modifiers :: (state: u32, except: Key) {
    MODIFIERS :: struct { mask: u32; key: Key; }.[
        .{X.ShiftMask,   .SHIFT},
        .{X.ControlMask, .CONTROL},
        .{X.Mod1Mask,    .ALT},
    ];
    for MODIFIERS {
        held := (state & it.mask) != 0;
        if it.key != except && held != input.key_down[it.key] input_on_key(xx it.key, held);
    }
}

on_button :: (event: *X.XButtonEvent, down: bool) {
    sync_modifiers(event.state, .UNKNOWN);
    if input.synthetic return;
    if event.button == 4 || event.button == 5 {   // The wheel: a press per notch.
        if down {
            input.wheel += ifx event.button == 4 then 1.0 else -1.0;
            platform.needs_redraw = true;
        }
        return;
    }
    button: Mouse_Button;
    if event.button == {
        case 1; button = .LEFT;
        case 2; button = .MIDDLE;
        case 3; button = .RIGHT;
        case;   return;   // Horizontal wheel, back and forward.
    }
    x, y := cast(float) event.x, cast(float) event.y;
    input_on_mouse_move(x, y);
    input_on_mouse_button(button, down);
    // Released outside the window: now it has left.
    if !down && (x < 0 || y < 0 || x >= cast(float) platform.width || y >= cast(float) platform.height) {
        if !input.mouse_down[0] && !input.mouse_down[1] && !input.mouse_down[2] input_on_mouse_leave();
    }
}

window_is_hidden :: () -> bool {
    type: X.Atom;
    format: s32;
    count, after: u64;
    data: *u8;
    hidden := false;
    if X.XGetWindowProperty(display, window, atoms._NET_WM_STATE, 0, 64, X.False, X.XA_ATOM, *type, *format, *count, *after, *data) == X.Success && data {
        states := cast(*X.Atom) data;
        for 0..cast(s64) count - 1 if states[it] == atoms._NET_WM_STATE_HIDDEN hidden = true;
        X.XFree(data);
    }
    return hidden;
}

// The scale: UPPIES_SCALE, else Xft.dpi / 96, else 1.
update_scale :: () {
    override := to_string(POSIX.getenv("UPPIES_SCALE"));
    if override {
        value, ok := string_to_float(override);
        if ok && value > 0 { platform.dpi_scale = clamp(cast(float) value, 0.5, 4); return; }
    }
    scale: float = 1;
    // XResourceManagerString is read when the connection opens; the root
    // window's property has what the settings say now.
    type: X.Atom;
    format: s32;
    count, after: u64;
    data: *u8;
    if X.XGetWindowProperty(display, root, atoms.RESOURCE_MANAGER, 0, 1_000_000, X.False, X.XA_STRING, *type, *format, *count, *after, *data) == X.Success && data {
        dpi := parse_xft_dpi(to_string(data, cast(s64) count));
        if dpi > 0 scale = dpi / 96;
        X.XFree(data);
    }
    platform.dpi_scale = clamp(scale, 0.5, 4);
}

// The display settings changed the scale while running: keep the window's
// size in logical units, as Windows does when moving between monitors.
on_scale_changed :: (old: float) {
    w := cast(u32) (platform.width  * platform.dpi_scale / old + 0.5);
    h := cast(u32) (platform.height * platform.dpi_scale / old + 0.5);
    update_size_hints();
    X.XResizeWindow(display, window, w, h);
    platform.needs_redraw = true;
}

// Text on the clipboard. X has no clipboard storage: the program that
// copied answers everyone who pastes, so we keep the text while we own it.

Clipboard :: struct {
    owned: bool;
    text:  string;
}
clipboard: Clipboard;

clipboard_answer :: (request: *X.XSelectionRequestEvent) {
    reply: X.XEvent;
    reply.xselection.type      = X.SelectionNotify;
    reply.xselection.requestor = request.requestor;
    reply.xselection.selection = request.selection;
    reply.xselection.target    = request.target;
    reply.xselection.time      = request.time;
    reply.xselection.property  = X.None;   // Refused, unless set below.

    property := ifx request.property then request.property else request.target;   // Obsolete clients give none.
    if request.selection == atoms.CLIPBOARD && clipboard.owned {
        if request.target == atoms.TARGETS {
            targets := s64.[xx atoms.TARGETS, xx atoms.UTF8_STRING, xx X.XA_STRING, xx atoms.TEXT];
            X.XChangeProperty(display, request.requestor, property, X.XA_ATOM, 32, X.PropModeReplace, xx targets.data, targets.count);
            reply.xselection.property = property;
        } else if request.target == atoms.UTF8_STRING || request.target == atoms.TEXT || request.target == X.XA_STRING {
            // Bigger than one request needs the INCR protocol, which we don't speak.
            if clipboard.text.count < 256 * 1024 {
                type := ifx request.target == X.XA_STRING then X.XA_STRING else atoms.UTF8_STRING;
                text := ifx type == X.XA_STRING then utf8_to_latin1(clipboard.text) else clipboard.text;
                X.XChangeProperty(display, request.requestor, property, type, 8, X.PropModeReplace, text.data, xx text.count);
                reply.xselection.property = property;
            }
        }
    }
    X.XSendEvent(display, request.requestor, X.False, 0, *reply);
}

// Asks the owner for the clipboard as `target` and waits up to a second for
// it. Only the reply is taken from the queue: other events stay for the main
// loop, so input isn't handled in the middle of a frame.
clipboard_request :: (target: X.Atom) -> string, bool {
    X.XDeleteProperty(display, window, atoms.UPPIES_SELECTION);
    X.XConvertSelection(display, atoms.CLIPBOARD, target, atoms.UPPIES_SELECTION, window, last_event_time);
    X.XFlush(display);
    deadline := seconds_since_init() + 1;
    reply: X.XEvent;
    while !X.XCheckTypedWindowEvent(display, window, X.SelectionNotify, *reply) {
        // Someone may ask us for a selection meanwhile (a clipboard manager).
        request: X.XEvent;
        while X.XCheckTypedWindowEvent(display, window, X.SelectionRequest, *request) clipboard_answer(*request.xselectionrequest);
        remaining := deadline - seconds_since_init();
        if remaining <= 0 {
            log_error("The clipboard's owner didn't answer.\n");
            return "", false;
        }
        fd := POSIX.pollfd.{fd = X.XConnectionNumber(display), events = POSIX.POLLIN};
        POSIX.poll(*fd, 1, cast(s32) (remaining * 1000) + 1);
    }
    if reply.xselection.property == X.None return "", false;

    type: X.Atom;
    format: s32;
    count, after: u64;
    data: *u8;
    if X.XGetWindowProperty(display, window, atoms.UPPIES_SELECTION, 0, 0x7FFF_FFFF, X.True, X.AnyPropertyType, *type, *format, *count, *after, *data) != X.Success || !data {
        return "", false;
    }
    defer X.XFree(data);
    if type == atoms.INCR {
        log_error("The clipboard holds too much text to paste.\n");
        return "", false;
    }
    if format != 8 return "", false;
    raw := to_string(data, cast(s64) count);
    if type == X.XA_STRING return latin1_to_utf8(raw), true;
    return copy_string(raw,, temp), true;
}

// Quitting: what we copied would go with us. A clipboard manager, if one is
// running, takes a copy when asked.
clipboard_hand_over :: () {
    if !clipboard.owned return;
    manager := X.XInternAtom(display, "CLIPBOARD_MANAGER", X.False);
    save := X.XInternAtom(display, "SAVE_TARGETS", X.False);
    if X.XGetSelectionOwner(display, manager) == X.None return;
    X.XConvertSelection(display, manager, save, X.None, window, last_event_time);
    X.XFlush(display);
    // The manager now asks us for the text; answer until it's done.
    deadline := seconds_since_init() + 1;
    while seconds_since_init() < deadline {
        event: X.XEvent;
        if X.XCheckTypedWindowEvent(display, window, X.SelectionRequest, *event) {
            clipboard_answer(*event.xselectionrequest);
            continue;
        }
        if X.XCheckTypedWindowEvent(display, window, X.SelectionNotify, *event) break;
        fd := POSIX.pollfd.{fd = X.XConnectionNumber(display), events = POSIX.POLLIN};
        POSIX.poll(*fd, 1, 50);
    }
}

latin1_to_utf8 :: (s: string) -> string {
    builder: String_Builder;
    builder.allocator = temp;
    for cast([] u8) s {
        if it < 0x80 append(*builder, it);
        else { append(*builder, cast(u8) (0xC0 | (it >> 6))); append(*builder, cast(u8) (0x80 | (it & 0x3F))); }
    }
    return builder_to_string(*builder,, temp);
}

utf8_to_latin1 :: (s: string) -> string {
    builder: String_Builder;
    builder.allocator = temp;
    i := 0;
    while i < s.count {
        cp := next_code_point(s, *i);
        append(*builder, cast(u8) ifx cp < 256 then cp else #char "?");
    }
    return builder_to_string(*builder,, temp);
}

// Refresh rate: the monitor (CRTC) under a point, from XRandR. 60 Hz when
// XRandR isn't there.

Randr_Monitor :: struct { x, y, width, height: s32; hz: float; }

Randr :: struct {
    loaded: bool;
    event_base: s32;
    monitors: [..] Randr_Monitor;
    last_x, last_y: s32;
}
randr: Randr;

Xrandr :: struct {
    XRRQueryExtension:              (display: *X.Display, event_base: *s32, error_base: *s32) -> s32 #c_call;
    XRRSelectInput:                 (display: *X.Display, window: X.Window, mask: s32) #c_call;
    XRRGetScreenResourcesCurrent:   (display: *X.Display, window: X.Window) -> *XRRScreenResources #c_call;
    XRRFreeScreenResources:         (resources: *XRRScreenResources) #c_call;
    XRRGetCrtcInfo:                 (display: *X.Display, resources: *XRRScreenResources, crtc: u64) -> *XRRCrtcInfo #c_call;
    XRRFreeCrtcInfo:                (info: *XRRCrtcInfo) #c_call;
}
xrandr: Xrandr;

XRRScreenResources :: struct {
    timestamp:       X.Time;
    config_timestamp: X.Time;
    ncrtc:   s32;
    crtcs:   *u64;
    noutput: s32;
    outputs: *u64;
    nmode:   s32;
    modes:   *XRRModeInfo;
}

XRRModeInfo :: struct {
    id:          u64;
    width:       u32;
    height:      u32;
    dot_clock:   u64;
    h_sync_start, h_sync_end, h_total, h_skew: u32;
    v_sync_start, v_sync_end, v_total: u32;
    name:        *u8;
    name_length: u32;
    mode_flags:  u64;
}

XRRCrtcInfo :: struct {
    timestamp: X.Time;
    x, y:      s32;
    width, height: u32;
    mode:      u64;
    rotation:  u16;
    noutput:   s32;
    outputs:   *u64;
    rotations: u16;
    npossible: s32;
    possible:  *u64;
}

RR_Interlace  :: 0x10;
RR_DoubleScan :: 0x20;
RRScreenChangeNotify     :: 0;
RRScreenChangeNotifyMask :: 1;

randr_init :: () {
    if !dl_load(*xrandr, .["libXrandr.so.2"]) {
        log("XRandR is not available; assuming 60 Hz.\n");
        return;
    }
    error_base: s32;
    if !xrandr.XRRQueryExtension(display, *randr.event_base, *error_base) return;
    randr.loaded = true;
    xrandr.XRRSelectInput(display, root, RRScreenChangeNotifyMask);
    randr_load_monitors();
}

randr_load_monitors :: () {
    randr.monitors.count = 0;
    resources := xrandr.XRRGetScreenResourcesCurrent(display, root);
    if !resources return;
    defer xrandr.XRRFreeScreenResources(resources);
    for c: 0..resources.ncrtc - 1 {
        crtc := xrandr.XRRGetCrtcInfo(display, resources, resources.crtcs[c]);
        if !crtc continue;
        defer xrandr.XRRFreeCrtcInfo(crtc);
        if !crtc.mode || !crtc.width || !crtc.height continue;   // Off.
        for m: 0..resources.nmode - 1 {
            mode := *resources.modes[m];
            if mode.id != crtc.mode continue;
            v_total := cast(float64) mode.v_total;
            if mode.mode_flags & RR_DoubleScan v_total *= 2;
            if mode.mode_flags & RR_Interlace  v_total /= 2;
            if !mode.h_total || v_total <= 0 break;
            hz := cast(float) (cast(float64) mode.dot_clock / (cast(float64) mode.h_total * v_total));
            array_add(*randr.monitors, .{crtc.x, crtc.y, xx crtc.width, xx crtc.height, hz});
            break;
        }
    }
}

// x, y: the window's center in root coordinates (-1: where it was last).
update_refresh_rate :: (x: s32, y: s32) {
    if x < 0 && y < 0 { x, y = randr.last_x, randr.last_y; }
    randr.last_x, randr.last_y = x, y;
    hz: float = 60;
    for randr.monitors {
        if x >= it.x && y >= it.y && x < it.x + it.width && y < it.y + it.height { hz = it.hz; break; }
    }
    if hz < 24 || hz > 1000 hz = 60;
    if hz != platform.refresh_hz {
        platform.refresh_hz = hz;
        platform.needs_redraw = true;
    }
}

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
        modal_pump();
    }
    success, result := Process_Module.get_process_result(*process);
    if !success || result.type != .EXITED || result.exit_code == 127 return "", false;
    if result.exit_code != 0 return "", true;   // Cancelled.
    return builder_to_string(*out,, temp), true;
}

// Handles what can't wait while a dialog is open: the clipboard, pings,
// closing, exposure. Input is dropped (the dialog has it).
modal_pump :: () {
    while X.XPending(display) > 0 {
        event: X.XEvent;
        X.XNextEvent(display, *event);
        if event.type == {
            case X.KeyPress; #through;
            case X.KeyRelease; #through;
            case X.ButtonPress; #through;
            case X.ButtonRelease; #through;
            case X.MotionNotify;
                continue;
        }
        dispatch_event(*event);
    }
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
    POSIX.chmod(temp_c_string(path), POSIX.S_IRWXU);
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

// Which store the key is in (or will be): local.key once it exists, so data
// never splits between two keys; else the keyring when there is one. Sets
// what the UI calls it.
protect_choose_store :: () -> Key_Store {
    store := Key_Store.FILE;
    if !file_exists(key_file_path()) && POSIX.getenv("DBUS_SESSION_BUS_ADDRESS") && secret_load() store = .KEYRING;
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
            // A keyring that is there but doesn't work (no Secret Service
            // running behind the bus): a key file, while nothing needs the
            // keyring's key.
            log("The keyring is not available (%); keeping the key in a file.\n", error);
            ok = key_file_load(*protect_key);
            protect_choose_store();
        } else {
            log_error("The keyring did not give Uppies its key: %\n", error);
        }
    } else {
        ok = key_file_load(*protect_key);
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
    if ok {
        // Never replace a key file we couldn't use.
        if data.count != AES_KEY_SIZE return false;
        memcpy(key.data, data.data, AES_KEY_SIZE);
        return true;
    }
    if file_exists(path) return false;
    return make_key(key, (key: *[AES_KEY_SIZE] u8) -> bool { return platform_write_file_atomic(key_file_path(), key.*); });
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
libX11 :: #library,system "libX11";
libc   :: #library,system "libc";
XkbSetDetectableAutoRepeat :: (display: *X.Display, detectable: s32, supported: *s32) -> s32 #foreign libX11;
getrandom :: (buffer: *void, length: u64, flags: u32) -> s64 #foreign libc;
setlocale :: (category: s32, locale: *u8) -> *u8 #foreign libc;
LC_CTYPE :: 0;   // glibc's.

CWBackPixel      :: 1 << 1;
CWBitGravity     :: 1 << 4;
NorthWestGravity :: 1;
NotifyGrab       :: 1;
NotifyUngrab     :: 2;

// X cursor font shapes (cursorfont.h); the cursor theme draws them.
XC_left_ptr :: 68;
XC_hand2    :: 60;
XC_xterm    :: 152;

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
