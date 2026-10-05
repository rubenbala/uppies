// Platform layer: window, input, time, cursor, and the few OS services the
// app needs (clipboard, opening links, local time, per-user storage, secret
// storage, waking the UI from another thread).
//
// Everything OS-specific lives behind this file. The rest of the app only
// sees `platform` and `input` and the procedures declared here; each OS
// provides them in its own file (platform_windows.jai; later
// platform_macos.jai and platform_linux.jai).
//
// All positions and sizes here are physical pixels. `platform.dpi_scale` is
// the monitor's scale (1 at 96 DPI, 1.5 at 144 DPI...); the UI multiplies its
// logical sizes by it.

Platform_State :: struct {
    width:  s32 = 1;            // Client area, physical pixels.
    height: s32 = 1;
    dpi_scale:  float = 1;
    refresh_hz: float = 60;     // Of the monitor the window is on.

    has_focus      := true;
    minimized:      bool;
    quit_requested: bool;

    // Something happened that may change what is on screen (input, resize,
    // DPI change, the OS asking for a repaint). The main loop renders while
    // this is set or while animations are running, and sleeps otherwise.
    needs_redraw := true;

    // Called when the OS blocks the main loop (Win32's modal move/resize
    // loop), so the app keeps animating and redraws at the new size.
    modal_frame: #type ();
    in_modal_frame: bool;

    double_click_seconds: float = 0.5;
}

// Wall-clock time: UTC seconds since 1970 and the local offset from UTC.
Local_Time :: struct {
    utc_seconds:    s64;
    offset_minutes: s32;
}

platform: Platform_State;

Mouse_Button :: enum u8 { LEFT; RIGHT; MIDDLE; }

// Values match Windows virtual-key codes (letters and digits are ASCII);
// other platforms translate their key codes to these.
Key :: enum u16 {
    UNKNOWN   :: 0;
    BACKSPACE :: 0x08;
    TAB       :: 0x09;
    ENTER     :: 0x0D;
    SHIFT     :: 0x10;
    CONTROL   :: 0x11;
    ALT       :: 0x12;
    ESCAPE    :: 0x1B;
    SPACE     :: 0x20;
    PAGE_UP   :: 0x21;
    PAGE_DOWN :: 0x22;
    END       :: 0x23;
    HOME      :: 0x24;
    LEFT      :: 0x25;
    UP        :: 0x26;
    RIGHT     :: 0x27;
    DOWN      :: 0x28;
    DELETE    :: 0x2E;
    // '0'..'9' and 'A'..'Z' are their ASCII codes.
    F1        :: 0x70;
    F2        :: 0x71;
    F3        :: 0x72;
    F4        :: 0x73;
    F5        :: 0x74;
    F6        :: 0x75;
    F7        :: 0x76;
    F8        :: 0x77;
    F9        :: 0x78;
    F10       :: 0x79;
    F11       :: 0x7A;
    F12       :: 0x7B;
}

KEY_COUNT :: 256;

Cursor :: enum u8 { ARROW; HAND; TEXT; }

// Input for the current frame. Events accumulate between frames; edges
// (pressed/released) and accumulated values (wheel, text) are reset by
// input_end_frame once a frame has used them.
Input_State :: struct {
    mouse_x, mouse_y: float = -1;   // Pixels; -1 when outside.
    mouse_inside: bool;

    mouse_down:     [#run enum_highest_value(Mouse_Button) + 1] bool;
    mouse_pressed:  [#run enum_highest_value(Mouse_Button) + 1] bool;
    mouse_released: [#run enum_highest_value(Mouse_Button) + 1] bool;
    wheel: float;                   // Notches this frame, positive = away from the user.

    key_down:     [KEY_COUNT] bool;
    key_pressed:  [KEY_COUNT] bool; // Includes OS key repeat.
    key_released: [KEY_COUNT] bool;

    text: [..] u32;                 // Code points typed this frame.

    // A test script drives the mouse; the real one is ignored.
    synthetic: bool;
}

input: Input_State;

input_end_frame :: () {
    for * input.mouse_pressed  it.* = false;
    for * input.mouse_released it.* = false;
    for * input.key_pressed    it.* = false;
    for * input.key_released   it.* = false;
    input.wheel = 0;
    input.text.count = 0;
}

key_pressed :: inline (key: Key) -> bool { return input.key_pressed[cast(u16) key]; }
ctrl_down   :: inline () -> bool { return input.key_down[Key.CONTROL]; }
shift_down  :: inline () -> bool { return input.key_down[Key.SHIFT]; }
// Ctrl+letter: ctrl_letter_pressed(#char "F").
ctrl_letter_pressed :: inline (ascii: u8) -> bool { return input.key_down[Key.CONTROL] && input.key_pressed[ascii]; }
key_down    :: inline (key: Key) -> bool { return input.key_down[cast(u16) key]; }
// Letters and digits: letter_pressed(#char "V").
letter_pressed :: inline (ascii: u8) -> bool { return input.key_pressed[ascii]; }

// Shared by the OS layers: record events into `input` and request a redraw.

input_on_mouse_move :: (x: float, y: float) {
    input.mouse_x = x;
    input.mouse_y = y;
    input.mouse_inside = true;
    platform.needs_redraw = true;
}

input_on_mouse_leave :: () {
    input.mouse_inside = false;
    input.mouse_x = -1;
    input.mouse_y = -1;
    platform.needs_redraw = true;
}

input_on_mouse_button :: (button: Mouse_Button, down: bool) {
    if down {
        if !input.mouse_down[button] input.mouse_pressed[button] = true;
    } else {
        if input.mouse_down[button] input.mouse_released[button] = true;
    }
    input.mouse_down[button] = down;
    platform.needs_redraw = true;
}

input_on_key :: (code: int, down: bool) {
    if code <= 0 || code >= KEY_COUNT return;
    if down {
        input.key_pressed[code] = true;
    } else if input.key_down[code] {
        input.key_released[code] = true;
    }
    input.key_down[code] = down;
    platform.needs_redraw = true;
}

input_release_all :: () {
    for 0..KEY_COUNT - 1 if input.key_down[it] input_on_key(it, false);
    for input.mouse_down if it input_on_mouse_button(xx it_index, false);
}

#if OS == .WINDOWS {
    #load "platform_windows.jai";
} else {
    #assert false "Uppies currently runs on Windows only; macOS and Linux platform layers come next.";
}
