// The X11 window system (Xlib), for platform_linux.jai: X11 sessions, and
// Wayland ones through XWayland when the native Wayland layer can't be used
// (linux_wayland.jai).
//
// - One window, drawn only by the Vulkan backend (render/vulkan). Vulkan's
//   window system code talks to the X server over a connection of its own
//   (platform_x11_vk_display), so its threads never read the events of the
//   one the main loop waits on.
// - Sizes are physical pixels like everywhere else. The scale is Xft.dpi /
//   96 (what the desktop's display settings set; 1.5 at 144 DPI), or
//   UPPIES_SCALE when set, and follows changes made while running.
// - The main loop sleeps in poll() on the X connection and the eventfd that
//   platform_wake writes from any thread (Xlib is only ever called from the
//   main thread).
// - X has no modal loop: a window being dragged or resized keeps sending
//   events to the main loop, so platform.modal_frame is never needed.
// - Until the first frame is drawn, the window shows a background color
//   close to the theme's (platform_set_dark_appearance), so it never flashes
//   white.

// For the Vulkan backend: a Display* and the window, as Vulkan's Xlib surface
// takes them.
platform_x11_vk_display: *void;
platform_x11_window: u64;

// The window's id, for dialogs that place themselves over it (zenity --attach).
x11_window_id :: () -> u64 { return window; }

x11_init :: (title: string, logical_width: int, logical_height: int) -> bool {
    // Input methods compose text in the user's locale (set by platform_init).
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
    attributes.background_pixel = background_pixel(linux_dark_background);
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

    randr_init();
    platform.width, platform.height = w, h;
    update_refresh_rate(x + w / 2, y + h / 2);
    X.XFlush(display);
    return true;
}

// Called once the first frame has been rendered.
x11_show_window :: () {
    if !window return;
    X.XMapRaised(display, window);
    X.XFlush(display);
}

// The window's title bar and the background shown before the first frame,
// dark or light to match the theme. The title bar follows window managers
// that read GTK's hint (Mutter, Xfwm); the rest draw their own theme.
x11_set_dark_appearance :: (dark: bool) {
    if !window return;
    X.XSetWindowBackground(display, window, background_pixel(dark));
    set_theme_variant();
}

x11_shutdown :: () {
    if !display return;
    clipboard_hand_over();
    if input_context X.XDestroyIC(input_context);
    if input_method  X.XCloseIM(input_method);
    for cursors if it X.XFreeCursor(display, it);
    if window X.XDestroyWindow(display, window);
    if platform_x11_vk_display && platform_x11_vk_display != display X.XCloseDisplay(platform_x11_vk_display);
    X.XCloseDisplay(display);
    display, window, input_method, input_context = null, 0, null, null;
    platform_x11_vk_display, platform_x11_window = null, 0;
}

// Handles every pending event without blocking.
x11_pump_events :: () {
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
x11_wait_for_events :: (timeout_seconds: float64 = -1) {
    if !display return;
    if X.XPending(display) > 0 return;   // Also sends what we have queued for the server.
    fds: [2] POSIX.pollfd;
    fds[0].fd, fds[0].events = X.XConnectionNumber(display), POSIX.POLLIN;
    fds[1].fd, fds[1].events = linux_wake_fd, POSIX.POLLIN;
    POSIX.poll(fds.data, fds.count, linux_poll_timeout(timeout_seconds));
    if fds[1].revents & POSIX.POLLIN linux_drain_wake();
}

x11_clipboard_get :: () -> string {   // Temporary storage.
    if !display return "";
    if clipboard.owned return copy_string(clipboard.text,, temp);
    if X.XGetSelectionOwner(display, atoms.CLIPBOARD) == X.None return "";
    text, ok := clipboard_request(atoms.UTF8_STRING);
    if !ok text = clipboard_request(X.XA_STRING);   // An old program: Latin-1.
    return text;
}

x11_clipboard_set :: (text: string) {
    if !display return;
    free(clipboard.text);
    clipboard.text = copy_string(text);
    X.XSetSelectionOwner(display, atoms.CLIPBOARD, window, last_event_time);
    clipboard.owned = X.XGetSelectionOwner(display, atoms.CLIPBOARD) == window;
    if !clipboard.owned log_error("Could not take the clipboard.\n");
}

x11_set_cursor :: (cursor: Cursor) {
    if cursor == current_cursor return;
    current_cursor = cursor;
    if window X.XDefineCursor(display, window, cursors[cursor]);
}

x11_set_title :: (title: string) {
    if window set_title(title);
}

// While a dialog is open (platform_save_file_dialog): handles what can't
// wait (the clipboard, pings, closing, exposure) and drops input, which is
// the dialog's.
x11_modal_pump :: () {
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

#scope_file

X     :: #import "X11";
POSIX :: #import "POSIX";

display: *X.Display;
screen: s32;
root: X.Window;
window: X.Window;
input_method: X.XIM;
input_context: X.XIC;
current_cursor: Cursor;
cursors: [#run enum_highest_value(Cursor) + 1] X.Cursor;
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
    variant := ifx linux_dark_background then "dark" else "light";
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


libX11 :: #library,system "libX11";
XkbSetDetectableAutoRepeat :: (display: *X.Display, detectable: s32, supported: *s32) -> s32 #foreign libX11;
libc :: #library,system "libc";
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
