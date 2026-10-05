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

MIN_WINDOW_WIDTH  :: 640;   // Logical units.
MIN_WINDOW_HEIGHT :: 400;

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

// Sleeps until the OS has a message for us. An idle app costs nothing.
platform_wait_for_events :: () {
    MsgWaitForMultipleObjectsEx(0, null, INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
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
            input_on_mouse_leave();
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

win32_user32 :: #library,system "user32";
win32_dwmapi :: #library,system "dwmapi";

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
