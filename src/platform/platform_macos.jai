// Cocoa implementation of the platform layer.
//
// - One NSWindow whose content view is layer-backed by a CAMetalLayer; the
//   Metal backend (render/metal) presents into that layer and nothing else
//   draws in the window.
// - Sizes are physical pixels like everywhere else: points times the
//   window's backingScaleFactor, which is platform.dpi_scale (2 on Retina).
//   The window is sized in logical units as points.
// - The window is shown only after the first frame is rendered.
// - AppKit runs a nested loop while the window is live-resized (inside
//   sendEvent), which starves the main loop; windowDidResize: draws frames
//   through platform.modal_frame meanwhile, as WM_SIZE does on Windows.
// - Command and Control both drive Key.CONTROL, so the app's Ctrl shortcuts
//   are the Command shortcuts a Mac user expects.
//
// - Secrets at rest (the token, the store file's key) are sealed with
//   AES-256-GCM (CommonCrypto) under a key kept in the login Keychain, the
//   counterpart of DPAPI. Only the packaged app (a release build run from
//   Uppies.app) uses the Keychain; development builds keep the key in a file
//   and their data in a folder of their own (see platform_uses_keychain).

platform_metal_layer: *void;   // CAMetalLayer, for the Metal backend.

// How the UI names this platform and its parts.
PLATFORM_NAME         :: "macOS";
PLATFORM_DEVICE       :: "this Mac";
PLATFORM_SECRET_STORE := "the macOS Keychain";   // Development builds say otherwise (platform_init).
PLATFORM_ACCOUNT      :: "your Mac user account";
PLATFORM_TOKEN_STORED := "Encrypted with a key in your login Keychain";
MOD_KEY               :: "⌘";      // As written in shortcuts: ⌘F.
MOD_SEPARATOR         :: "";
MOD_CLICK             :: "⌘-click";
NEXT_PAGE_KEYS        :: "⌃Tab";   // ⌘Tab is the system's app switcher; Control drives Key.CONTROL too.

MIN_WINDOW_WIDTH  :: 1000;   // Logical units.
MIN_WINDOW_HEIGHT :: 620;

platform_init :: (title: string, logical_width: int, logical_height: int) -> bool {
    init_objective_c();
    init_app_kit();
    init_objective_c_selector_struct(*sel);
    cocoa_context = context;
    if !platform_uses_keychain() {
        PLATFORM_SECRET_STORE = "a development key file";
        PLATFORM_TOKEN_STORED = "Encrypted with this build's key file (development build)";
    }

    app := NSApplication.sharedApplication();
    NSApplication.setActivationPolicy(app, NSApplicationActivationPolicyRegular);
    define_classes();
    delegate = objc_init(objc_alloc(delegate_class));
    msg_send(app, sel.setDelegate_, delegate);
    create_menu(app, title);
    NSApplication.finishLaunching(app);

    // Logical units as points, fit to the screen's visible area, centered.
    screen := NSScreen.mainScreen();
    visible := msg_get(screen, sel.visibleFrame, NSRect);
    w := min(cast(float64) logical_width,  visible.size.width);
    h := min(cast(float64) logical_height, visible.size.height - 28);   // Title bar.
    content := NSMakeRect(0, 0, w, h);
    style := NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    window = NSWindow.initWithContentRect(objc_alloc(NSWindow), content, style, NSBackingStoreBuffered, NO, screen);
    if !window {
        log_error("Could not create the window.\n");
        return false;
    }
    NSWindow.setReleasedWhenClosed(window, NO);
    NSWindow.setTitle(window, title);
    NSWindow.setDelegate(window, delegate);
    msg_send(window, sel.setContentMinSize_, NSMakeSize(MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT));
    msg_send(window, sel.setAcceptsMouseMovedEvents_, YES);
    msg_send(window, sel.setTabbingMode_, cast(NSInteger) 2);   // NSWindowTabbingModeDisallowed.
    NSWindow.setCollectionBehavior(window, NSWindowCollectionBehaviorFullScreenPrimary | NSWindowCollectionBehaviorManaged);

    view = xx objc_init(objc_alloc(view_class));
    NSView.setWantsLayer(view, YES);   // Asks makeBackingLayer for the CAMetalLayer.
    msg_send(view, sel.setLayerContentsRedrawPolicy_, cast(NSInteger) 2);   // NSViewLayerContentsRedrawDuringViewResize.
    NSWindow.setContentView(window, view);
    NSWindow.makeFirstResponder(window, view);
    release(view);   // The window holds it.
    NSWindow.center(window);

    // Mouse moves, enters and leaves over the whole view, whatever its size.
    options: NSUInteger = NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingCursorUpdate | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
    tracking := msg_get(objc_alloc(objc_getClass("NSTrackingArea")), sel.initWithRect_options_owner_userInfo_, NSRect.{}, options, view, cast(*void) null, *void);
    msg_send(view, sel.addTrackingArea_, tracking);
    release(tracking);

    platform.double_click_seconds = cast(float) msg_get_float(objc_getClass("NSEvent"), sel.doubleClickInterval);
    update_scale();
    update_client_size();
    update_refresh_rate();
    return true;
}

// Called once the first frame has been rendered.
platform_show_window :: () {
    NSWindow.makeKeyAndOrderFront(window, null);
    NSApplication.activateIgnoringOtherApps(NSApp, YES);
}

// The window's title bar and controls in dark or light, to match the theme.
platform_set_dark_appearance :: (dark: bool) {
    if !window return;
    name := NSString.getTempString(ifx dark then "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua");
    appearance := msg_get(objc_getClass("NSAppearance"), sel.appearanceNamed_, name, *void);
    if appearance msg_send(window, sel.setAppearance_, appearance);
}

platform_shutdown :: () {
    if window {
        NSWindow.setDelegate(window, null);
        NSWindow.close(window);
        release(window);
    }
    window = null;
    view = null;
}

// Handles every pending event without blocking.
platform_pump_events :: () {
    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);
    distant_past := NSDate.distantPast();
    while true {
        event := NSApplication.nextEventMatchingMask(NSApp, NSEventMaskAny, distant_past, NSDefaultRunLoopMode, YES);
        if !event break;
        dispatch_event(event);
    }
}

// Sleeps until the OS has an event for us, or until timeout_seconds pass
// (negative: no timeout). An idle app costs nothing.
platform_wait_for_events :: (timeout_seconds: float64 = -1) {
    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);
    until: *NSDate;
    if timeout_seconds >= 0 until = msg_get_with_float(objc_getClass("NSDate"), sel.dateWithTimeIntervalSinceNow_, timeout_seconds);
    else                    until = NSDate.distantFuture();
    // Dequeued here, so dispatch it; the main loop pumps the rest.
    event := NSApplication.nextEventMatchingMask(NSApp, NSEventMaskAny, until, NSDefaultRunLoopMode, YES);
    if event dispatch_event(event);
}

// Wakes the main loop from any thread (a network reply arrived).
platform_wake :: () {
    if !window return;
    // Worker threads have no autorelease pool of their own.
    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);
    event := msg_get(objc_getClass("NSEvent"), sel.otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2_,
                 NSEventTypeApplicationDefined, NSPoint.{}, cast(NSUInteger) 0, cast(float64) 0, cast(NSInteger) 0, cast(*void) null,
                 cast(s16) WAKE_SUBTYPE, cast(NSInteger) 0, cast(NSInteger) 0, *NSEvent);
    if event msg_send(NSApp, sel.postEvent_atStart_, event, NO);   // Thread-safe.
}

platform_open_url :: (url: string) {
    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);
    // A local path (the data folder) isn't a URL: "Application Support"
    // has a space, which URLWithString rejects.
    ns_url := ifx begins_with(url, "/") then NSURL.fileURLWithPath(NSString.getTempString(url)) else NSURL.URLWithString(NSString.getTempString(url));
    if !ns_url return;
    workspace := msg_get(objc_getClass("NSWorkspace"), sel.sharedWorkspace, *void);
    msg_get(workspace, sel.openURL_, ns_url, BOOL);
}

// Asks where to save a file, with the system's Save panel, starting from
// `suggested_name`. `type_name` and `extension` ("PDF document", "pdf")
// describe the file; the panel adds the extension and asks before
// replacing a file. Blocks until the panel closes. Returns the path chosen
// (temporary storage), or false when cancelled.
platform_save_file_dialog :: (title: string, suggested_name: string, type_name: string, extension: string) -> path: string, ok: bool {
    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);
    panel := NSSavePanel.savePanel();
    msg_send(panel, sel.setTitle_, NSString.getTempString(title));
    NSSavePanel.setNameFieldStringValue(panel, NSString.getTempString(suggested_name));
    ext := NSString.getTempString(extension);
    NSSavePanel.setAllowedFileTypes(panel, NSArray(*NSString).arrayWithObject(ext));
    chosen := NSSavePanel.runModal(panel) == NSModalResponseOK;

    // The panel took the keyboard and mouse: whatever was held when it
    // opened was released there.
    input_release_all();
    platform.needs_redraw = true;
    if !chosen return "", false;
    url := NSSavePanel.URL(panel);
    if !url return "", false;
    return copy_string(to_string(NSURL.path(url)),, temp), true;
}

platform_clipboard_get :: () -> string {   // Temporary storage.
    text := os_clipboard_get_text();
    result := copy_string(text,, temp);
    free(text);
    return result;
}

platform_clipboard_set :: (text: string) {
    os_clipboard_set_text(text);
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

// Per-user app directory (~/Library/Application Support/Uppies), created on
// first use. Development builds use "Uppies Dev" beside it: their data is
// sealed with another key, and the packaged app would throw it away (and the
// other way round) if they shared a folder.
platform_app_data_dir :: () -> string {
    if !app_data_dir {
        home := to_string(NSHomeDirectory());
        base := ifx home then tprint("%/Library/Application Support", home) else exe_dir;
        app_data_dir = sprint("%/%", base, ifx platform_uses_keychain() then "Uppies" else "Uppies Dev");
        make_directory_if_it_does_not_exist(app_data_dir, recursive = true);
    }
    return app_data_dir;
}

// Points every per-user file at another folder (testing: -data-dir).
platform_set_app_data_dir :: (path: string) {
    free(app_data_dir);
    app_data_dir = copy_string(path);
    make_directory_if_it_does_not_exist(app_data_dir, recursive = true);
}

// The packaged app: a release build running from Uppies.app. Only it keeps
// its key in the Keychain. Every other build is a new app to the Keychain each
// time it is linked (ad hoc signatures change with the code), so it would be
// asked for the key after every rebuild.
platform_uses_keychain :: () -> bool {
    return APP_RELEASE && ends_with(exe_dir, "/Contents/MacOS");
}

// Secrets at rest are sealed with AES-256-GCM under a key kept in the
// user's login Keychain: only this user on this Mac can open them, the
// counterpart of DPAPI. (Development builds: under a key in a file, see
// key_file_load.) Optional `entropy` must be given again to decrypt,
// binding the secret to something else the app knows.
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

// Cryptographically secure random bytes from the OS.
platform_random_bytes :: (out: [] u8) -> bool {
    arc4random_buf(out.data, cast(u64) out.count);
    return true;
}

// AES-256-GCM (CommonCrypto). `aad` is authenticated but not encrypted.
// Returns the ciphertext (same length as plain, heap) and the tag.
platform_aes_gcm_encrypt :: (key: [] u8, nonce: [] u8, aad: [] u8, plain: [] u8) -> cipher: [] u8, tag: [AES_TAG_SIZE] u8, ok: bool {
    tag: [AES_TAG_SIZE] u8;
    if key.count != AES_KEY_SIZE || nonce.count != AES_NONCE_SIZE return .[], tag, false;
    cipher := NewArray(plain.count, u8, initialized = false);
    status := CCCryptorGCMOneshotEncrypt(kCCAlgorithmAES, key.data, xx key.count, nonce.data, xx nonce.count,
                                         non_null(aad), xx aad.count, non_null(plain), xx plain.count,
                                         non_null(cipher), tag.data, AES_TAG_SIZE);
    if status != kCCSuccess { array_free(cipher); return .[], tag, false; }
    return cipher, tag, true;
}

// Fails if the ciphertext, tag or aad were altered, or the key or nonce are
// wrong: nothing unauthenticated is ever returned.
platform_aes_gcm_decrypt :: (key: [] u8, nonce: [] u8, aad: [] u8, cipher: [] u8, tag: [AES_TAG_SIZE] u8) -> plain: [] u8, ok: bool {
    if key.count != AES_KEY_SIZE || nonce.count != AES_NONCE_SIZE return .[], false;
    plain := NewArray(cipher.count, u8, initialized = false);
    tag_copy := tag;
    status := CCCryptorGCMOneshotDecrypt(kCCAlgorithmAES, key.data, xx key.count, nonce.data, xx nonce.count,
                                         non_null(aad), xx aad.count, non_null(cipher), xx cipher.count,
                                         non_null(plain), tag_copy.data, AES_TAG_SIZE);
    if status != kCCSuccess {
        if plain.count memset(plain.data, 0, plain.count);
        array_free(plain);
        return .[], false;
    }
    return plain, true;
}

// Replaces `path` with `data` in one step: written beside it, flushed to
// disk, then renamed over it. A crash leaves the old file or the new one,
// never a mixture.
platform_write_file_atomic :: (path: string, data: [] u8) -> bool {
    tmp := tprint("%.tmp", path);
    c_tmp := temp_c_string(tmp);
    fd := POSIX.open(c_tmp, POSIX.O_WRONLY | POSIX.O_CREAT | POSIX.O_TRUNC, POSIX.S_IRUSR | POSIX.S_IWUSR);
    if fd < 0 return false;
    at := 0;
    ok := true;
    while at < data.count {
        written := POSIX.write(fd, data.data + at, cast(u64) (data.count - at));
        if written <= 0 { ok = false; break; }
        at += written;
    }
    // fsync only reaches the drive's cache on macOS; F_FULLFSYNC reaches the disk.
    if ok ok = POSIX.fcntl(fd, POSIX.F_FULLFSYNC) == 0 || POSIX.fsync(fd) == 0;
    POSIX.close(fd);
    if ok ok = POSIX.rename(c_tmp, temp_c_string(path)) == 0;
    if !ok POSIX.unlink(c_tmp);
    return ok;
}

platform_set_cursor :: (cursor: Cursor) {
    if cursor == current_cursor return;
    current_cursor = cursor;
    if input.mouse_inside apply_cursor();
}

platform_set_title :: (title: string) {
    if window NSWindow.setTitle(window, title);
}

platform_sleep_until :: (deadline_seconds: float64) {
    // Coarse sleep, then spin the last stretch for precision.
    while true {
        remaining := deadline_seconds - seconds_since_init();
        if remaining <= 0 break;
        if remaining > 0.002 POSIX.usleep(cast(u32) ((remaining - 0.0015) * 1_000_000));
    }
}

#scope_file

using,except(Category) ObjC :: #import "Objective_C";
#import "Objective_C/AppKit";
POSIX :: #import "POSIX";
CF :: #import "macOS";

cocoa_context: #Context;
window: *NSWindow;
view: *NSView;
delegate: id;
view_class, delegate_class: Class;
app_data_dir: string;
current_cursor: Cursor;
modifiers: NSUInteger;   // NSEventModifierFlags as last seen.
reported: [2] string;

WAKE_SUBTYPE :: 0x5550;   // "UP"

// Selectors the Objective_C module has no wrapper for. Each '_' is a ':'.
Selectors :: struct {
    setDelegate_: Selector;
    visibleFrame: Selector;
    setContentMinSize_: Selector;
    setAcceptsMouseMovedEvents_: Selector;
    setTabbingMode_: Selector;
    setLayerContentsRedrawPolicy_: Selector;
    initWithRect_options_owner_userInfo_: Selector;
    addTrackingArea_: Selector;
    doubleClickInterval: Selector;
    dateWithTimeIntervalSinceNow_: Selector;
    otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2_: Selector;
    postEvent_atStart_: Selector;
    subtype: Selector;
    sharedWorkspace: Selector;
    openURL_: Selector;
    setTitle_: Selector;
    locationInWindow: Selector;
    scrollingDeltaY: Selector;
    hasPreciseScrollingDeltas: Selector;
    inLiveResize: Selector;
    isMiniaturized: Selector;
    screen: Selector;
    maximumFramesPerSecond: Selector;
    keyWindow: Selector;
    layer: Selector;
    setContentsScale_: Selector;
    addItem_: Selector;
    separatorItem: Selector;
    hide_: Selector;
    hideOtherApplications_: Selector;
    unhideAllApplications_: Selector;
    performMiniaturize_: Selector;
    terminate_: Selector;
    appearanceNamed_: Selector;
    setAppearance_: Selector;
}
sel: Selectors;

// Typed objc_msgSend. msg_send: no result; msg_get: a result of type R.
// Floats have procedures of their own: the compiler merged msg_get's
// float64-argument and pointer-argument instantiations into one, putting
// arguments in d0 where x2 was meant.
msg_send :: (self: *void, s: Selector) #no_context {
    (cast(#type (*void, Selector) -> void #c_call) objc_msgSend)(self, s);
}
msg_send :: (self: *void, s: Selector, a: $A) #no_context {
    (cast(#type (*void, Selector, A) -> void #c_call) objc_msgSend)(self, s, a);
}
msg_send :: (self: *void, s: Selector, a: $A, b: $B) #no_context {
    (cast(#type (*void, Selector, A, B) -> void #c_call) objc_msgSend)(self, s, a, b);
}
msg_get :: (self: *void, s: Selector, $R: Type) -> R #no_context {
    return (cast(#type (*void, Selector) -> R #c_call) objc_msgSend)(self, s);
}
msg_get :: (self: *void, s: Selector, a: $A, $R: Type) -> R #no_context {
    return (cast(#type (*void, Selector, A) -> R #c_call) objc_msgSend)(self, s, a);
}
msg_get :: (self: *void, s: Selector, a: $A, b: $B, $R: Type) -> R #no_context {
    return (cast(#type (*void, Selector, A, B) -> R #c_call) objc_msgSend)(self, s, a, b);
}
msg_get :: (self: *void, s: Selector, a: $A, b: $B, c: $C, d: $D, $R: Type) -> R #no_context {
    return (cast(#type (*void, Selector, A, B, C, D) -> R #c_call) objc_msgSend)(self, s, a, b, c, d);
}
msg_get :: (self: *void, s: Selector, a: $A, b: $B, c: $C, d: $D, e: $E, f_: $F, g: $G, h: $H, i: $I, $R: Type) -> R #no_context {
    return (cast(#type (*void, Selector, A, B, C, D, E, F, G, H, I) -> R #c_call) objc_msgSend)(self, s, a, b, c, d, e, f_, g, h, i);
}

// A float64 (CGFloat, NSTimeInterval) argument or result.
msg_send_float :: (self: *void, s: Selector, a: float64) #no_context {
    (cast(#type (*void, Selector, float64) -> void #c_call) objc_msgSend)(self, s, a);
}
msg_get_float :: (self: *void, s: Selector) -> float64 #no_context {
    return (cast(#type (*void, Selector) -> float64 #c_call) objc_msgSend)(self, s);
}
msg_get_with_float :: (self: *void, s: Selector, a: float64) -> *void #no_context {
    return (cast(#type (*void, Selector, float64) -> *void #c_call) objc_msgSend)(self, s, a);
}

NSApplicationActivationPolicyRegular :: 0;
NSTerminateCancel :: 0;
NSTrackingMouseEnteredAndExited :: 0x01;
NSTrackingMouseMoved            :: 0x02;
NSTrackingCursorUpdate          :: 0x04;
NSTrackingActiveInKeyWindow     :: 0x20;
NSTrackingInVisibleRect         :: 0x200;

arc4random_buf :: (buffer: *void, size: u64) #foreign libSystem;

// The key behind platform_protect: in the packaged app one generic password
// item in the Keychain, otherwise a file; made on first use. Loaded once and
// kept for the session; the UI thread (the token) and the store writer thread
// both use it.
PROTECT_MAGIC  :: "UPK1";
PROTECT_HEADER :: PROTECT_MAGIC.count + AES_NONCE_SIZE;   // Then the ciphertext, then the tag.
KEYCHAIN_SERVICE :: "Uppies";
KEYCHAIN_ACCOUNT :: "local-key";
KEYCHAIN_LABEL   :: "Uppies local encryption key";

protect_key:    [AES_KEY_SIZE] u8;
protect_loaded: bool;
protect_failed: bool;   // Refused once: don't ask again this session.
protect_lock:   u32;    // os_unfair_lock; zero is unlocked, so no setup.

protect_load_key :: () -> bool {
    os_unfair_lock_lock(*protect_lock);
    defer os_unfair_lock_unlock(*protect_lock);
    if protect_loaded return true;
    if protect_failed return false;
    if !platform_uses_keychain() {
        if !key_file_load(*protect_key) {
            memset(protect_key.data, 0, protect_key.count);
            protect_failed = true;
            log_error("Could not read or make the development key file in %.\n", platform_app_data_dir());
            return false;
        }
        protect_loaded = true;
        return true;
    }
    status := keychain_read(*protect_key);
    if status == errSecItemNotFound {
        if !platform_random_bytes(protect_key) return false;
        status = keychain_add(*protect_key);
        if status == errSecDuplicateItem status = keychain_read(*protect_key);   // Another copy of the app made one first.
    }
    if status != errSecSuccess {
        // Never replace an item we couldn't read: that would lock away
        // everything already sealed with it.
        memset(protect_key.data, 0, protect_key.count);
        protect_failed = true;
        log_error("The Keychain did not give Uppies its key (OSStatus %).\n", status);
        return false;
    }
    protect_loaded = true;
    return true;
}

// Development builds: the key in local.key beside the data it protects,
// readable only by this user (0600). Weaker than the Keychain: anything
// running as this user can read the file, so it never holds the packaged
// app's key (its data is in another folder).
key_file_load :: (key: *[AES_KEY_SIZE] u8) -> bool {
    path := tprint("%/local.key", platform_app_data_dir());
    data, ok := read_entire_file(path,, temp);
    if ok {
        // Never replace a key file we couldn't use, as with the Keychain.
        if data.count != AES_KEY_SIZE return false;
        memcpy(key.data, data.data, AES_KEY_SIZE);
        return true;
    }
    if file_exists(path) return false;
    if !platform_random_bytes(key.*) return false;
    return platform_write_file_atomic(path, key.*);
}

keychain_read :: (key: *[AES_KEY_SIZE] u8) -> s32 {
    service := CF.cfstring_from_string(KEYCHAIN_SERVICE);
    account := CF.cfstring_from_string(KEYCHAIN_ACCOUNT);
    defer { CF.CFRelease(service); CF.CFRelease(account); }
    keys   := *void.[kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit];
    values := *void.[kSecClassGenericPassword, service, account, CF.kCFBooleanTrue, kSecMatchLimitOne];
    query := CF.CFDictionaryCreate(null, keys.data, values.data, keys.count, *CF.kCFTypeDictionaryKeyCallBacks, *CF.kCFTypeDictionaryValueCallBacks);
    defer CF.CFRelease(query);
    data: CF.CFDataRef;
    status := SecItemCopyMatching(query, *data);
    if status != errSecSuccess return status;
    defer CF.CFRelease(data);
    if CF.CFDataGetLength(data) != AES_KEY_SIZE return errSecDecode;
    memcpy(key.data, CF.CFDataGetBytePtr(data), AES_KEY_SIZE);
    return errSecSuccess;
}

keychain_add :: (key: *[AES_KEY_SIZE] u8) -> s32 {
    service := CF.cfstring_from_string(KEYCHAIN_SERVICE);
    account := CF.cfstring_from_string(KEYCHAIN_ACCOUNT);
    label   := CF.cfstring_from_string(KEYCHAIN_LABEL);
    data    := CF.CFDataCreate(null, key.data, AES_KEY_SIZE);
    defer { CF.CFRelease(service); CF.CFRelease(account); CF.CFRelease(label); CF.CFRelease(data); }
    keys   := *void.[kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrLabel, kSecValueData];
    values := *void.[kSecClassGenericPassword, service, account, label, data];
    attributes := CF.CFDictionaryCreate(null, keys.data, values.data, keys.count, *CF.kCFTypeDictionaryKeyCallBacks, *CF.kCFTypeDictionaryValueCallBacks);
    defer CF.CFRelease(attributes);
    return SecItemAdd(attributes, null);
}

// The aad of a sealed secret: the app's name and the caller's entropy.
protect_aad :: (entropy: string) -> string { return tprint("Uppies%", entropy); }

as_bytes :: (s: string) -> [] u8 {
    b: [] u8;
    b.data, b.count = s.data, s.count;
    return b;
}

security :: #library,system "Security";
errSecSuccess       :: 0;
errSecDuplicateItem :: -25299;
errSecItemNotFound  :: -25300;
errSecDecode        :: -26275;
kSecClass:                *void #elsewhere security;
kSecClassGenericPassword: *void #elsewhere security;
kSecAttrService:          *void #elsewhere security;
kSecAttrAccount:          *void #elsewhere security;
kSecAttrLabel:            *void #elsewhere security;
kSecValueData:            *void #elsewhere security;
kSecReturnData:           *void #elsewhere security;
kSecMatchLimit:           *void #elsewhere security;
kSecMatchLimitOne:        *void #elsewhere security;
SecItemCopyMatching :: (query: CF.CFDictionaryRef, result: *CF.CFDataRef) -> s32 #foreign security;
SecItemAdd :: (attributes: CF.CFDictionaryRef, result: *void) -> s32 #foreign security;

os_unfair_lock_lock   :: (lock: *u32) #foreign libSystem;
os_unfair_lock_unlock :: (lock: *u32) #foreign libSystem;

// AES-GCM in one call. CommonCrypto exports these from libSystem (since
// macOS 10.13); the self-test checks them against a NIST vector.
kCCAlgorithmAES :: 0;
kCCSuccess      :: 0;
CCCryptorGCMOneshotEncrypt :: (alg: u32, key: *void, key_length: u64, iv: *void, iv_length: u64, aad: *void, aad_length: u64,
                               data_in: *void, data_in_length: u64, cipher_out: *void, tag_out: *void, tag_length: u64) -> s32 #foreign libSystem;
CCCryptorGCMOneshotDecrypt :: (alg: u32, key: *void, key_length: u64, iv: *void, iv_length: u64, aad: *void, aad_length: u64,
                               data_in: *void, data_in_length: u64, data_out: *void, tag_in: *void, tag_length: u64) -> s32 #foreign libSystem;

// CommonCrypto rejects null buffers even when they are empty.
non_null :: (bytes: [] u8) -> *void {
    return ifx bytes.data then cast(*void) bytes.data else *empty_buffer;
}
empty_buffer: u8;
libSystem :: #library,system "libSystem";

not_yet :: (what: string) {
    for reported if it == what return;
    for * reported if !it.* { it.* = what; break; }
    log("% is not available on macOS yet.\n", what);
}

// The application menu: the few commands every Mac app answers to.
create_menu :: (app: *NSApplication, title: string) {
    S :: NSString.getTempString;
    bar := objc_init(objc_alloc(NSMenu));
    app_item := NSMenu.addItemWithTitle(bar, S(""), null, S(""));
    menu := objc_init(objc_alloc(NSMenu));
    NSMenu.addItemWithTitle(menu, S(tprint("Hide %", title)), sel.hide_, S("h"));
    others := NSMenu.addItemWithTitle(menu, S("Hide Others"), sel.hideOtherApplications_, S("h"));
    NSMenuItem.setKeyEquivalentModifierMask(others, NSEventModifierFlagCommand | NSEventModifierFlagOption);
    NSMenu.addItemWithTitle(menu, S("Show All"), sel.unhideAllApplications_, S(""));
    msg_send(menu, sel.addItem_, msg_get(objc_getClass("NSMenuItem"), sel.separatorItem, *void));
    NSMenu.addItemWithTitle(menu, S("Minimize"), sel.performMiniaturize_, S("m"));
    msg_send(menu, sel.addItem_, msg_get(objc_getClass("NSMenuItem"), sel.separatorItem, *void));
    // terminate: asks the app delegate, which turns it into quit_requested.
    NSMenu.addItemWithTitle(menu, S(tprint("Quit %", title)), sel.terminate_, S("q"));
    NSMenuItem.setSubmenu(app_item, menu);
    NSApplication.setMainMenu(app, bar);
    release(menu);
    release(bar);
}

dispatch_event :: (event: *NSEvent) {
    type := NSEvent.type(event);
    if type == NSEventTypeApplicationDefined && msg_get(event, sel.subtype, s16) == WAKE_SUBTYPE {
        platform.needs_redraw = true;
        return;
    }
    // AppKit doesn't deliver key-up to the window while Command is held
    // (it may be a menu shortcut); without this, Command+C leaves C down.
    if type == NSEventTypeKeyUp && (flags_of(event) & COMMAND) {
        on_key(event, false);
        return;
    }
    NSApplication.sendEvent(NSApp, event);
}

define_classes :: () {
    view_class = objc_allocateClassPair(objc_getClass("NSView"), "UppiesView");
    objc_add_instance_method(view_class, view_make_backing_layer, "makeBackingLayer");
    objc_add_instance_method(view_class, view_yes, "wantsUpdateLayer");
    objc_add_instance_method(view_class, view_yes, "acceptsFirstResponder");
    objc_add_instance_method(view_class, view_yes_with, "acceptsFirstMouse:");
    objc_add_instance_method(view_class, view_mouse_down, "mouseDown:");
    objc_add_instance_method(view_class, view_mouse_down, "rightMouseDown:");
    objc_add_instance_method(view_class, view_mouse_down, "otherMouseDown:");
    objc_add_instance_method(view_class, view_mouse_up, "mouseUp:");
    objc_add_instance_method(view_class, view_mouse_up, "rightMouseUp:");
    objc_add_instance_method(view_class, view_mouse_up, "otherMouseUp:");
    objc_add_instance_method(view_class, view_mouse_moved, "mouseMoved:");
    objc_add_instance_method(view_class, view_mouse_moved, "mouseDragged:");
    objc_add_instance_method(view_class, view_mouse_moved, "rightMouseDragged:");
    objc_add_instance_method(view_class, view_mouse_moved, "otherMouseDragged:");
    objc_add_instance_method(view_class, view_mouse_moved, "mouseEntered:");
    objc_add_instance_method(view_class, view_mouse_exited, "mouseExited:");
    objc_add_instance_method(view_class, view_cursor_update, "cursorUpdate:");
    objc_add_instance_method(view_class, view_scroll_wheel, "scrollWheel:");
    objc_add_instance_method(view_class, view_key_down, "keyDown:");
    objc_add_instance_method(view_class, view_key_up, "keyUp:");
    objc_add_instance_method(view_class, view_flags_changed, "flagsChanged:");
    objc_add_instance_method(view_class, view_backing_changed, "viewDidChangeBackingProperties");
    objc_finalize_class(view_class);

    // Window and application delegate in one.
    delegate_class = objc_allocateClassPair(objc_getClass("NSObject"), "UppiesDelegate");
    objc_add_instance_method(delegate_class, window_should_close, "windowShouldClose:");
    objc_add_instance_method(delegate_class, window_did_resize, "windowDidResize:");
    objc_add_instance_method(delegate_class, window_focus_gained, "windowDidBecomeKey:");
    objc_add_instance_method(delegate_class, window_focus_lost, "windowDidResignKey:");
    objc_add_instance_method(delegate_class, window_minimized, "windowDidMiniaturize:");
    objc_add_instance_method(delegate_class, window_restored, "windowDidDeminiaturize:");
    objc_add_instance_method(delegate_class, window_screen_changed, "windowDidChangeScreen:");
    objc_add_instance_method(delegate_class, window_screen_changed, "windowDidChangeBackingProperties:");
    objc_add_instance_method(delegate_class, app_should_terminate, "applicationShouldTerminate:");
    objc_finalize_class(delegate_class);
}

// The view.

view_make_backing_layer :: (self: id, _sel: Selector) -> id #c_call {
    push_context cocoa_context {
        layer := objc_init(objc_alloc(objc_getClass("CAMetalLayer")));
        platform_metal_layer = layer;
        return layer;
    }
}

view_yes      :: (self: id, _sel: Selector) -> BOOL #c_call { return YES; }
view_yes_with :: (self: id, _sel: Selector, event: id) -> BOOL #c_call { return YES; }

view_mouse_down :: (self: id, _sel: Selector, event: id) #c_call {
    push_context cocoa_context { on_mouse_button(xx event, true); }
}

view_mouse_up :: (self: id, _sel: Selector, event: id) #c_call {
    push_context cocoa_context { on_mouse_button(xx event, false); }
}

view_mouse_moved :: (self: id, _sel: Selector, event: id) #c_call {
    push_context cocoa_context {
        if input.synthetic return;
        x, y := mouse_position(xx event);
        if !input.mouse_inside apply_cursor();
        input_on_mouse_move(x, y);
    }
}

view_mouse_exited :: (self: id, _sel: Selector, event: id) #c_call {
    push_context cocoa_context {
        if input.synthetic return;
        // A drag that leaves the window keeps its mouse until released.
        if input.mouse_down[0] || input.mouse_down[1] || input.mouse_down[2] return;
        input_on_mouse_leave();
    }
}

view_cursor_update :: (self: id, _sel: Selector, event: id) #c_call {
    push_context cocoa_context { apply_cursor(); }
}

view_scroll_wheel :: (self: id, _sel: Selector, event: id) #c_call {
    push_context cocoa_context {
        dy := msg_get_float(event, sel.scrollingDeltaY);
        // A mouse wheel reports lines (about one per notch); a trackpad or
        // Magic Mouse reports points, turned into notches of the UI's
        // scroll step (three rows) so content follows the fingers.
        if msg_get(event, sel.hasPreciseScrollingDeltas, BOOL) dy /= PRECISE_POINTS_PER_NOTCH;
        input.wheel += cast(float) dy;
        platform.needs_redraw = true;
    }
}

PRECISE_POINTS_PER_NOTCH :: 84.0;   // 3 * theme.row_height.

view_key_down :: (self: id, _sel: Selector, event: id) #c_call {
    push_context cocoa_context {
        on_key(xx event, true);
        if flags_of(xx event) & (COMMAND | CONTROL) return;   // A shortcut, not text.
        chars := NSEvent.characters(xx event);
        if !chars return;
        text := to_string(chars);
        i := 0;
        while i < text.count {
            cp := next_code_point(text, *i);
            // Skip control characters and the function keys' private-use
            // code points (arrows, F1...: U+F700 to U+F8FF).
            if cp < 32 || cp == 127 || (cp >= 0xF700 && cp <= 0xF8FF) continue;
            array_add(*input.text, cp);
        }
        platform.needs_redraw = true;
    }
}

view_key_up :: (self: id, _sel: Selector, event: id) #c_call {
    push_context cocoa_context { on_key(xx event, false); }
}

view_flags_changed :: (self: id, _sel: Selector, event: id) #c_call {
    push_context cocoa_context {
        flags := flags_of(xx event);
        for MODIFIER_KEYS {
            was := (modifiers & it.mask) != 0;
            now := (flags & it.mask) != 0;
            if was != now input_on_key(xx it.key, now);
        }
        modifiers = flags;
    }
}

view_backing_changed :: (self: id, _sel: Selector) #c_call {
    push_context cocoa_context {
        update_scale();
        update_client_size();
    }
}

// The window and application delegate.

window_should_close :: (self: id, _sel: Selector, sender: id) -> BOOL #c_call {
    push_context cocoa_context { platform.quit_requested = true; }
    return NO;   // The main loop shuts down and closes it.
}

window_did_resize :: (self: id, _sel: Selector, notification: id) #c_call {
    push_context cocoa_context {
        update_client_size();
        platform.needs_redraw = true;
        // While the user drags an edge, AppKit is in its own loop: redraw
        // at the new size right away, as WM_SIZE does on Windows.
        if msg_get(window, sel.inLiveResize, BOOL) run_modal_frame();
    }
}

window_focus_gained :: (self: id, _sel: Selector, notification: id) #c_call {
    push_context cocoa_context {
        platform.has_focus = true;
        platform.needs_redraw = true;
    }
}

window_focus_lost :: (self: id, _sel: Selector, notification: id) #c_call {
    push_context cocoa_context {
        platform.has_focus = false;
        input_release_all();
        modifiers = 0;
    }
}

window_minimized :: (self: id, _sel: Selector, notification: id) #c_call {
    push_context cocoa_context { platform.minimized = true; }
}

window_restored :: (self: id, _sel: Selector, notification: id) #c_call {
    push_context cocoa_context {
        platform.minimized = false;
        platform.needs_redraw = true;
    }
}

window_screen_changed :: (self: id, _sel: Selector, notification: id) #c_call {
    push_context cocoa_context {
        update_scale();
        update_client_size();
        update_refresh_rate();
        platform.needs_redraw = true;
    }
}

app_should_terminate :: (self: id, _sel: Selector, sender: id) -> NSUInteger #c_call {
    push_context cocoa_context { platform.quit_requested = true; }
    return NSTerminateCancel;   // The main loop saves and exits on its own.
}

// Input helpers.

SHIFT   :: cast(NSUInteger) NSEventModifierFlagShift;
CONTROL :: cast(NSUInteger) NSEventModifierFlagControl;
OPTION  :: cast(NSUInteger) NSEventModifierFlagOption;
COMMAND :: cast(NSUInteger) NSEventModifierFlagCommand;

MODIFIER_KEYS :: struct { mask: NSUInteger; key: Key; }.[
    .{SHIFT, .SHIFT},
    .{COMMAND | CONTROL, .CONTROL},
    .{OPTION, .ALT},
];

flags_of :: (event: *NSEvent) -> NSUInteger {
    return cast(NSUInteger) NSEvent.modifierFlags(event);
}

// Top-left origin, physical pixels.
mouse_position :: (event: *NSEvent) -> float, float {
    p := msg_get(event, sel.locationInWindow, NSPoint);
    bounds := NSView.bounds(view);
    return cast(float) (p.x * platform.dpi_scale), cast(float) ((bounds.size.height - p.y) * platform.dpi_scale);
}

on_mouse_button :: (event: *NSEvent, down: bool) {
    if input.synthetic return;
    button: Mouse_Button;
    number := NSEvent.buttonNumber(event);
    if number == {
        case 0; button = .LEFT;
        case 1; button = .RIGHT;
        case 2; button = .MIDDLE;
        case;   return;
    }
    x, y := mouse_position(event);
    input_on_mouse_move(x, y);
    input_on_mouse_button(button, down);
    // Released outside the window: now it has left.
    if !down && (x < 0 || y < 0 || x >= cast(float) platform.width || y >= cast(float) platform.height) {
        if !input.mouse_down[0] && !input.mouse_down[1] && !input.mouse_down[2] input_on_mouse_leave();
    }
}

on_key :: (event: *NSEvent, down: bool) {
    code := NSEvent.keyCode(event);
    if code >= KEY_TABLE.count return;
    key := KEY_TABLE[code];
    if key != .UNKNOWN input_on_key(xx key, down);
}

apply_cursor :: () {
    c: *NSCursor;
    if current_cursor == {
        case .HAND; c = NSCursor.pointingHandCursor();
        case .TEXT; c = NSCursor.IBeamCursor();
        case;       c = NSCursor.arrowCursor();
    }
    NSCursor.set(c);
}

run_modal_frame :: () {
    if !platform.modal_frame || platform.in_modal_frame return;
    platform.in_modal_frame = true;
    platform.modal_frame();
    platform.in_modal_frame = false;
}

update_scale :: () {
    if !window return;
    scale := cast(float) NSWindow.backingScaleFactor(window);
    if scale <= 0 scale = 1;
    platform.dpi_scale = scale;
    if platform_metal_layer msg_send_float(platform_metal_layer, sel.setContentsScale_, scale);
}

update_client_size :: () {
    if !view return;
    bounds := NSView.bounds(view);
    platform.width  = cast(s32) max(bounds.size.width  * platform.dpi_scale + 0.5, 0);
    platform.height = cast(s32) max(bounds.size.height * platform.dpi_scale + 0.5, 0);
}

update_refresh_rate :: () {
    screen := msg_get(window, sel.screen, *void);
    if !screen return;
    hz := msg_get(screen, sel.maximumFramesPerSecond, NSInteger);
    platform.refresh_hz = ifx hz >= 24 && hz <= 1000 then cast(float) hz else 60;
}

// macOS virtual key codes (kVK_*, Carbon's Events.h) to the Key enum, which
// uses Windows virtual-key values.
KEY_TABLE :: #run make_key_table();

make_key_table :: () -> [128] Key {
    t: [128] Key;
    letters :: "ASDFHGZXCV\0BQWERYT123465=97-80]OU[IP\0LJ'K;\\,/NM.";   // kVK_ANSI_A (0) to kVK_ANSI_Period (47).
    for 0..letters.count - 1 {
        c := letters[it];
        if (c >= #char "A" && c <= #char "Z") || (c >= #char "0" && c <= #char "9") t[it] = cast(Key) c;
    }
    t[36]  = .ENTER;
    t[76]  = .ENTER;       // Keypad Enter.
    t[48]  = .TAB;
    t[49]  = .SPACE;
    t[51]  = .BACKSPACE;   // "Delete" on a Mac keyboard.
    t[117] = .DELETE;      // Forward delete.
    t[53]  = .ESCAPE;
    t[115] = .HOME;
    t[119] = .END;
    t[116] = .PAGE_UP;
    t[121] = .PAGE_DOWN;
    t[123] = .LEFT;
    t[124] = .RIGHT;
    t[125] = .DOWN;
    t[126] = .UP;
    t[122] = .F1;  t[120] = .F2;  t[99]  = .F3;  t[118] = .F4;
    t[96]  = .F5;  t[97]  = .F6;  t[98]  = .F7;  t[100] = .F8;
    t[101] = .F9;  t[109] = .F10; t[103] = .F11; t[111] = .F12;
    return t;
}
