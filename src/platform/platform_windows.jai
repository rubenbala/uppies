// Win32 implementation of the platform layer.
//
// - Per-monitor DPI aware (v2): the window is sized in logical units times
//   the monitor's scale and follows WM_DPICHANGED when dragged between
//   monitors, so text is always rasterized at the real pixel size.
// - No GDI redirection surface (WS_EX_NOREDIRECTIONBITMAP): the flip-model
//   swap chain is the only thing that ever presents into the window.
// - The window is shown only after the first frame is rendered, so it never
//   flashes white.
// - Win32 runs a modal loop while the window is moved or resized, which
//   starves the main loop; a timer and WM_SIZE keep frames coming then.

platform_window: HWND;

MIN_WINDOW_WIDTH  :: 1000;   // Logical units.
MIN_WINDOW_HEIGHT :: 620;

platform_init :: (title: string, logical_width: int, logical_height: int) -> bool {
    if !SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) SetProcessDPIAware();
    timeBeginPeriod(1);   // 1 ms Sleep granularity, for the frame limiter.

    window_proc_context = context;
    instance := cast(HINSTANCE) GetModuleHandleW(null);

    class_name := utf8_to_wide("UppiesWindow",, temp);
    wc: WNDCLASSEXW;
    wc.cbSize        = size_of(WNDCLASSEXW);
    wc.lpfnWndProc   = xx window_proc;
    wc.hInstance     = instance;
    wc.hIcon         = LoadIconW(instance, cast(*u16) 1);   // The exe's icon, if it has one.
    wc.lpszClassName = class_name;
    if !RegisterClassExW(*wc) {
        log_error("RegisterClassExW failed.\n");
        return false;
    }

    cursors[Cursor.ARROW] = LoadCursorW(null, IDC_ARROW);
    cursors[Cursor.HAND]  = LoadCursorW(null, IDC_HAND);
    cursors[Cursor.TEXT]  = LoadCursorW(null, IDC_IBEAM);

    // Created hidden at a placeholder size; once we know the DPI of the
    // monitor it landed on we size and center it properly.
    platform_window = CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP, class_name, utf8_to_wide(title,, temp), WS_OVERLAPPEDWINDOW,
                                      xx CW_USEDEFAULT, xx CW_USEDEFAULT, 800, 600, null, null, instance, null);
    if !platform_window {
        log_error("CreateWindowExW failed.\n");
        return false;
    }

    dpi := GetDpiForWindow(platform_window);
    if dpi == 0 dpi = 96;
    platform.dpi_scale = dpi / 96.0;
    platform.refresh_hz = xx detect_refresh_rate(platform_window);
    platform.double_click_seconds = GetDoubleClickTime() / 1000.0;

    // Size the client area in logical units, fit to the work area, center.
    w := cast(s32) (logical_width  * platform.dpi_scale);
    h := cast(s32) (logical_height * platform.dpi_scale);
    outer := RECT.{0, 0, w, h};
    AdjustWindowRectExForDpi(*outer, WS_OVERLAPPEDWINDOW, 0, WS_EX_NOREDIRECTIONBITMAP, dpi);
    ow := outer.right - outer.left;
    oh := outer.bottom - outer.top;
    monitor_info: MONITORINFO;
    monitor_info.cbSize = size_of(MONITORINFO);
    if GetMonitorInfoW(MonitorFromWindow(platform_window, MONITOR_DEFAULTTONEAREST), *monitor_info) {
        work := monitor_info.rcWork;
        ow = min(ow, work.right - work.left);
        oh = min(oh, work.bottom - work.top);
        x := work.left + (work.right - work.left - ow) / 2;
        y := work.top + (work.bottom - work.top - oh) / 2;
        SetWindowPos(platform_window, null, x, y, ow, oh, SWP_NOZORDER | SWP_NOACTIVATE);
    }

    // Dark title bar to match the UI (Windows 10 2004+; ignored elsewhere).
    dark: s32 = 1;
    DwmSetWindowAttribute(platform_window, DWMWA_USE_IMMERSIVE_DARK_MODE, *dark, size_of(s32));

    update_client_size();
    return true;
}

// Called once the first frame has been rendered.
platform_show_window :: () {
    ShowWindow(platform_window, SW_SHOW);
}

platform_shutdown :: () {
    if platform_window DestroyWindow(platform_window);
    platform_window = null;
    timeEndPeriod(1);
}

// Handles every pending OS message without blocking.
platform_pump_events :: () {
    msg: MSG;
    while PeekMessageW(*msg, null, 0, 0, PM_REMOVE) {
        if msg.message == WM_QUIT {
            platform.quit_requested = true;
            continue;
        }
        TranslateMessage(*msg);
        DispatchMessageW(*msg);
    }
}

// Sleeps until the OS has a message for us, or until timeout_seconds pass
// (negative: no timeout). An idle app costs nothing.
platform_wait_for_events :: (timeout_seconds: float64 = -1) {
    ms: u32 = INFINITE;
    if timeout_seconds >= 0 ms = cast(u32) min(timeout_seconds * 1000 + 1, 3_600_000.0);
    MsgWaitForMultipleObjectsEx(0, null, ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
}

// Wakes the main loop from any thread (a network reply arrived).
platform_wake :: () {
    if platform_window PostMessageW(platform_window, WM_APP_WAKE, 0, 0);
}

platform_open_url :: (url: string) {
    ShellExecuteW(null, utf8_to_wide("open",, temp), utf8_to_wide(url,, temp), null, null, SW_SHOWNORMAL);
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
    utc, local: SYSTEMTIME;
    GetSystemTime(*utc);
    GetLocalTime(*local);
    to_seconds :: (t: SYSTEMTIME) -> s64 {
        days := days_from_civil(t.wYear, t.wMonth, t.wDay);
        return days * 86400 + t.wHour * 3600 + t.wMinute * 60 + t.wSecond;
    }
    result: Local_Time;
    result.utc_seconds = to_seconds(utc);
    diff := to_seconds(local) - result.utc_seconds;
    result.offset_minutes = cast(s32) ((diff + (ifx diff >= 0 then 30 else -30)) / 60);
    return result;
}

// Per-user app directory (%APPDATA%/Uppies), created on first use.
platform_app_data_dir :: () -> string {
    if !app_data_dir {
        buffer: [1024] u16;
        n := GetEnvironmentVariableW(utf8_to_wide("APPDATA",, temp), buffer.data, buffer.count);
        base := ifx n > 0 && n < buffer.count then wide_to_utf8(buffer.data, cast(s32) n,, temp) else exe_dir;
        app_data_dir = sprint("%/Uppies", base);
        for 0..app_data_dir.count - 1 if app_data_dir[it] == #char "\\" app_data_dir[it] = #char "/";
        make_directory_if_it_does_not_exist(app_data_dir, recursive = true);
    }
    return app_data_dir;
}

// Secrets at rest are encrypted with DPAPI: only this Windows user on this
// machine can decrypt them.
platform_protect :: (plain: string) -> string, bool {
    input_blob := DATA_BLOB.{cast(u32) plain.count, plain.data};
    output_blob: DATA_BLOB;
    if !CryptProtectData(*input_blob, utf8_to_wide("Uppies",, temp), null, null, null, CRYPTPROTECT_UI_FORBIDDEN, *output_blob) return "", false;
    result := copy_string(string.{output_blob.cbData, output_blob.pbData});
    LocalFree(output_blob.pbData);
    return result, true;
}

platform_unprotect :: (cipher: string) -> string, bool {
    input_blob := DATA_BLOB.{cast(u32) cipher.count, cipher.data};
    output_blob: DATA_BLOB;
    if !CryptUnprotectData(*input_blob, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, *output_blob) return "", false;
    result := copy_string(string.{output_blob.cbData, output_blob.pbData});
    memset(output_blob.pbData, 0, output_blob.cbData);
    LocalFree(output_blob.pbData);
    return result, true;
}

platform_set_cursor :: (cursor: Cursor) {
    if cursor == current_cursor return;
    current_cursor = cursor;
    if input.mouse_inside SetCursor(cursors[cursor]);
}

platform_set_title :: (title: string) {
    SetWindowTextW(platform_window, utf8_to_wide(title,, temp));
}

platform_sleep_until :: (deadline_seconds: float64) {
    // Coarse sleep, then spin the last stretch for precision.
    while true {
        remaining := deadline_seconds - seconds_since_init();
        if remaining <= 0 break;
        if remaining > 0.002 Sleep(cast(s32) ((remaining - 0.0015) * 1000));
    }
}

#scope_file

window_proc_context: #Context;
app_data_dir: string;
cursors: [#run enum_highest_value(Cursor) + 1] HCURSOR;
current_cursor: Cursor;
tracking_mouse: bool;
in_size_move: bool;    // Inside Win32's modal move/resize loop.
high_surrogate: u32;

MODAL_TIMER_ID :: 1;

window_proc :: (hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> s64 #c_call {
    push_context window_proc_context {
        return handle_message(hwnd, message, wparam, lparam);
    }
}

handle_message :: (hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> s64 {
    if message == {
        case WM_CLOSE;
            platform.quit_requested = true;
            return 0;

        case WM_ERASEBKGND;
            return 1;   // The swap chain covers everything.

        case WM_APP_WAKE;
            platform.needs_redraw = true;
            return 0;

        case WM_PAINT;
            ValidateRect(hwnd, null);
            platform.needs_redraw = true;
            if in_size_move run_modal_frame();
            return 0;

        case WM_SIZE;
            update_client_size();
            platform.minimized = wparam == SIZE_MINIMIZED;
            platform.needs_redraw = true;
            // While dragging, redraw at the new size right away; otherwise
            // the main loop does it after this round of messages.
            if in_size_move run_modal_frame();
            return 0;

        case WM_ENTERSIZEMOVE;
            interval := cast(u32) max(1000 / max(cast(int) platform.refresh_hz, 1), 1);
            SetTimer(hwnd, MODAL_TIMER_ID, interval, null);
            in_size_move = true;
            return 0;

        case WM_EXITSIZEMOVE;
            KillTimer(hwnd, MODAL_TIMER_ID);
            in_size_move = false;
            platform.refresh_hz = xx detect_refresh_rate(hwnd);   // May be on another monitor now.
            return 0;

        case WM_TIMER;
            if wparam == MODAL_TIMER_ID {
                run_modal_frame();
                return 0;
            }

        case WM_DPICHANGED;
            platform.dpi_scale = (wparam & 0xFFFF) / 96.0;
            suggested := cast(*RECT) lparam;
            SetWindowPos(hwnd, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, SWP_NOZORDER | SWP_NOACTIVATE);
            platform.refresh_hz = xx detect_refresh_rate(hwnd);
            platform.needs_redraw = true;
            return 0;

        case WM_GETMINMAXINFO;
            info := cast(*MINMAXINFO) lparam;
            dpi := GetDpiForWindow(hwnd);
            if dpi == 0 dpi = 96;
            border: RECT;
            AdjustWindowRectExForDpi(*border, WS_OVERLAPPEDWINDOW, 0, WS_EX_NOREDIRECTIONBITMAP, dpi);
            info.ptMinTrackSize.x = cast(s32) (MIN_WINDOW_WIDTH  * dpi / 96) + (border.right - border.left);
            info.ptMinTrackSize.y = cast(s32) (MIN_WINDOW_HEIGHT * dpi / 96) + (border.bottom - border.top);
            return 0;

        case WM_SETFOCUS;
            platform.has_focus = true;
            platform.needs_redraw = true;
            return 0;

        case WM_KILLFOCUS;
            platform.has_focus = false;
            input_release_all();
            return 0;

        case WM_SETCURSOR;
            if (lparam & 0xFFFF) == HTCLIENT {
                SetCursor(cursors[current_cursor]);
                return 1;
            }

        case WM_MOUSEMOVE;
            if input.synthetic return 0;
            if !tracking_mouse {
                tme: TRACKMOUSEEVENT;
                tme.cbSize    = size_of(TRACKMOUSEEVENT);
                tme.dwFlags   = TME_LEAVE;
                tme.hwndTrack = hwnd;
                TrackMouseEvent(*tme);
                tracking_mouse = true;
            }
            input_on_mouse_move(xx lparam_x(lparam), xx lparam_y(lparam));
            return 0;

        case WM_MOUSELEAVE;
            tracking_mouse = false;
            if !input.synthetic input_on_mouse_leave();
            return 0;

        case WM_LBUTTONDOWN; #through;
        case WM_LBUTTONDBLCLK;
            mouse_button(hwnd, .LEFT, true, lparam);  return 0;
        case WM_LBUTTONUP;   mouse_button(hwnd, .LEFT, false, lparam);  return 0;
        case WM_RBUTTONDOWN; mouse_button(hwnd, .RIGHT, true, lparam);  return 0;
        case WM_RBUTTONUP;   mouse_button(hwnd, .RIGHT, false, lparam); return 0;
        case WM_MBUTTONDOWN; mouse_button(hwnd, .MIDDLE, true, lparam);  return 0;
        case WM_MBUTTONUP;   mouse_button(hwnd, .MIDDLE, false, lparam); return 0;

        case WM_MOUSEWHEEL;
            input.wheel += cast,no_check(s16) ((wparam >> 16) & 0xFFFF) / 120.0;
            platform.needs_redraw = true;
            return 0;

        case WM_KEYDOWN; #through;
        case WM_SYSKEYDOWN;
            input_on_key(xx wparam, true);
            if message == WM_SYSKEYDOWN return DefWindowProcW(hwnd, message, wparam, lparam);   // Alt+F4.
            return 0;

        case WM_KEYUP; #through;
        case WM_SYSKEYUP;
            input_on_key(xx wparam, false);
            if message == WM_SYSKEYUP return DefWindowProcW(hwnd, message, wparam, lparam);
            return 0;

        case WM_CHAR;
            unit := cast(u32) wparam;
            if unit >= 0xD800 && unit <= 0xDBFF {
                high_surrogate = unit;
            } else {
                code_point := unit;
                if unit >= 0xDC00 && unit <= 0xDFFF && high_surrogate {
                    code_point = 0x10000 + ((high_surrogate - 0xD800) << 10) + (unit - 0xDC00);
                }
                high_surrogate = 0;
                if code_point >= 32 && code_point != 127 array_add(*input.text, code_point);
                platform.needs_redraw = true;
            }
            return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

mouse_button :: (hwnd: HWND, button: Mouse_Button, down: bool, lparam: LPARAM) {
    if input.synthetic return;
    // Capture so a drag that leaves the window still gets its release.
    if down SetCapture(hwnd);
    input_on_mouse_move(xx lparam_x(lparam), xx lparam_y(lparam));
    input_on_mouse_button(button, down);
    if !down && !input.mouse_down[0] && !input.mouse_down[1] && !input.mouse_down[2] ReleaseCapture();
}

lparam_x :: inline (lparam: LPARAM) -> s32 { return cast,no_check(s16) (lparam & 0xFFFF); }
lparam_y :: inline (lparam: LPARAM) -> s32 { return cast,no_check(s16) ((lparam >> 16) & 0xFFFF); }

run_modal_frame :: () {
    if !platform.modal_frame || platform.in_modal_frame return;
    platform.in_modal_frame = true;
    platform.modal_frame();
    platform.in_modal_frame = false;
}

update_client_size :: () {
    r: RECT;
    GetClientRect(platform_window, *r);
    platform.width  = max(r.right - r.left, 0);
    platform.height = max(r.bottom - r.top, 0);
}

detect_refresh_rate :: (hwnd: HWND) -> int {
    FALLBACK :: 60;
    monitor := MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if !monitor return FALLBACK;
    info: MONITORINFOEXA;
    info.cbSize = size_of(MONITORINFOEXA);
    if !GetMonitorInfoA(monitor, cast(*MONITORINFO) *info) return FALLBACK;
    mode: DEVMODEA;
    mode.dmSize = size_of(DEVMODEA);
    if !EnumDisplaySettingsA(info.szDevice.data, ENUM_CURRENT_SETTINGS, *mode) return FALLBACK;
    hz := cast(int) mode.dmDisplayFrequency;
    if hz < 24 || hz > 1000 return FALLBACK;
    return hz;
}

// Win32 declarations the Windows module does not have.

win32_user32   :: #library,system "user32";
win32_dwmapi   :: #library,system "dwmapi";
win32_shell32  :: #library,system "shell32";
win32_crypt32  :: #library,system "crypt32";
win32_kernel32 :: #library,system "kernel32";

WM_APP_WAKE   :: 0x8000 + 1;   // WM_APP + 1
SW_SHOWNORMAL :: 1;
CRYPTPROTECT_UI_FORBIDDEN :: 0x1;

DATA_BLOB :: struct {
    cbData: u32;
    pbData: *u8;
}

DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 :: -4;
DWMWA_USE_IMMERSIVE_DARK_MODE :: 20;
SIZE_MINIMIZED :: 1;
HTCLIENT       :: 1;
WM_MOUSELEAVE  :: 0x02A3;
TME_LEAVE      :: 0x2;
QS_ALLINPUT    :: 0x04FF;
MWMO_INPUTAVAILABLE :: 0x4;

TRACKMOUSEEVENT :: struct {
    cbSize:      u32;
    dwFlags:     u32;
    hwndTrack:   HWND;
    dwHoverTime: u32;
}

MINMAXINFO :: struct {
    ptReserved:     POINT;
    ptMaxSize:      POINT;
    ptMaxPosition:  POINT;
    ptMinTrackSize: POINT;
    ptMaxTrackSize: POINT;
}

// The context argument is a pseudo-handle (a small negative number).
SetProcessDpiAwarenessContext :: (dpi_context: s64) -> s32 #foreign win32_user32;
GetDpiForWindow :: (hwnd: HWND) -> u32 #foreign win32_user32;
AdjustWindowRectExForDpi :: (rect: *RECT, style: u32, menu: s32, ex_style: u32, dpi: u32) -> s32 #foreign win32_user32;
MsgWaitForMultipleObjectsEx :: (count: u32, handles: *HANDLE, milliseconds: u32, wake_mask: u32, flags: u32) -> u32 #foreign win32_user32;
TrackMouseEvent :: (tme: *TRACKMOUSEEVENT) -> s32 #foreign win32_user32;
SetTimer  :: (hwnd: HWND, timer_id: u64, interval_ms: u32, callback: *void) -> u64 #foreign win32_user32;
KillTimer :: (hwnd: HWND, timer_id: u64) -> s32 #foreign win32_user32;
DwmSetWindowAttribute :: (hwnd: HWND, attribute: u32, value: *void, size: u32) -> s32 #foreign win32_dwmapi;
PostMessageW :: (hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> s32 #foreign win32_user32;
GetDoubleClickTime :: () -> u32 #foreign win32_user32;
ShellExecuteW :: (hwnd: HWND, operation: *u16, file: *u16, parameters: *u16, directory: *u16, show: s32) -> *void #foreign win32_shell32;
GetEnvironmentVariableW :: (name: *u16, buffer: *u16, size: u32) -> u32 #foreign win32_kernel32;
CryptProtectData :: (data_in: *DATA_BLOB, description: *u16, entropy: *DATA_BLOB, reserved: *void, prompt: *void, flags: u32, data_out: *DATA_BLOB) -> s32 #foreign win32_crypt32;
CryptUnprotectData :: (data_in: *DATA_BLOB, description: **u16, entropy: *DATA_BLOB, reserved: *void, prompt: *void, flags: u32, data_out: *DATA_BLOB) -> s32 #foreign win32_crypt32;
