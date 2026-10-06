// Scripted runs, for screenshots and checks without a person at the mouse:
//
//   uppies.exe -demo -size 1440x900 -script "wait 3; page transactions; key DOWN; shot out.png; quit"
//
// Steps run in order, separated by ';':
//   wait SECONDS      let the app run (animations, sample-data loading)
//   page NAME         overview, transactions, accounts, spending, tags, webhooks, settings
//   shot PATH         save the next frame as a PNG
//   key NAME          press a key for one frame: DOWN, UP, ENTER, ESCAPE, TAB, F5, A..Z, 0..9
//   ctrl NAME         the same with Ctrl held
//   text STRING       type text
//   move X Y          move the mouse (logical units)
//   click X Y         click there
//   ctrlclick X Y     click there with Ctrl held (shiftclick: with Shift)
//   wheel N           scroll (positive: up)
//   quit
//
// A scripted run never reads or writes the saved token or settings.

Script :: struct {
    active: bool;
    steps:  [..] string;
    at:     int;
    wait_until: float64;
    release_next: bool;
    release_key: int;
    release_ctrl: bool;
    release_shift: bool;
    shot_path: string;    // Captured after the next render.
}

script: Script;
persist_enabled := true;

script_load :: (text: string) {
    script.active = true;
    persist_enabled = false;
    for split(text, ";") {
        step := trim(it);
        if step.count array_add(*script.steps, copy_string(step));
    }
}

// Runs the steps that are due; called at the start of every frame, before
// the UI sees the frame's input (like real input, which arrives first).
script_frame :: () {
    if !script.active return;
    ui.animating = true;   // Keep frames coming while the script runs.

    if script.release_next {
        script.release_next = false;
        if input.mouse_down[Mouse_Button.LEFT] input_on_mouse_button(.LEFT, false);
        if script.release_key input_on_key(script.release_key, false);
        if script.release_ctrl input_on_key(cast(int) Key.CONTROL, false);
        if script.release_shift input_on_key(cast(int) Key.SHIFT, false);
        script.release_key = 0;
        script.release_ctrl = false;
        script.release_shift = false;
        return;
    }
    now := seconds_since_init();
    if now < script.wait_until return;

    while script.at < script.steps.count {
        step := script.steps[script.at];
        script.at += 1;
        parts := split(step, " ",, temp);
        command := to_lower_temp(parts[0]);
        arg := ifx parts.count > 1 then trim(slice(step, parts[0].count, step.count - parts[0].count)) else "";
        if command == {
            case "wait";
                seconds, ok := string_to_float(arg);
                script.wait_until = now + ifx ok then seconds else 1.0;
                return;
            case "page";
                for PAGE_TITLES if to_lower_temp(it) == to_lower_temp(arg) select_page(cast(Page) it_index);
            case "shot";
                free(script.shot_path);
                script.shot_path = copy_string(arg);
                return;   // One shot per frame.
            case "key"; #through;
            case "ctrl";
                code := key_code(arg);
                if code {
                    if command == "ctrl" { input_on_key(cast(int) Key.CONTROL, true); script.release_ctrl = true; }
                    input_on_key(code, true);
                    script.release_key = code;
                    script.release_next = true;
                }
                return;
            case "text";
                i := 0;
                while i < arg.count array_add(*input.text, next_code_point(arg, *i));
                return;
            case "move";
                input.synthetic = true;
                x, y := parse_point(arg);
                input_on_mouse_move(x, y);
                return;
            case "click"; #through;
            case "ctrlclick"; #through;
            case "shiftclick";
                if command == "ctrlclick"  { input_on_key(cast(int) Key.CONTROL, true); script.release_ctrl = true; }
                if command == "shiftclick" { input_on_key(cast(int) Key.SHIFT, true); script.release_shift = true; }
                input.synthetic = true;
                x, y := parse_point(arg);
                input_on_mouse_move(x, y);
                input_on_mouse_button(.LEFT, true);
                script.release_next = true;
                return;
            case "wheel";
                n, ok := string_to_float(arg);
                if ok input.wheel += n;
                platform.needs_redraw = true;
                return;
            case "quit";
                platform.quit_requested = true;
                return;
            case;
                log_error("Script: unknown step '%'\n", step);
        }
    }
    script.active = script.at < script.steps.count || script.shot_path.count > 0;
}

// Called between render and present.
script_after_render :: () {
    if !script.shot_path.count return;
    if renderer_capture_png(script.shot_path) log("Saved %\n", script.shot_path);
    else log_error("Could not save %\n", script.shot_path);
    free(script.shot_path);
    script.shot_path = "";
}

#scope_file

parse_point :: (arg: string) -> float, float {
    parts := split(arg, " ",, temp);
    x, y: float;
    if parts.count >= 2 {
        x = string_to_float(parts[0]);
        y = string_to_float(parts[parts.count - 1]);
    }
    return x * ui.scale, y * ui.scale;
}

key_code :: (name_in: string) -> int {
    name := to_upper_temp(name_in);
    if name.count == 1 return name[0];
    if name == {
        case "DOWN";     return xx Key.DOWN;
        case "UP";       return xx Key.UP;
        case "LEFT";     return xx Key.LEFT;
        case "RIGHT";    return xx Key.RIGHT;
        case "ENTER";    return xx Key.ENTER;
        case "ESCAPE";   return xx Key.ESCAPE;
        case "TAB";      return xx Key.TAB;
        case "SPACE";    return xx Key.SPACE;
        case "HOME";     return xx Key.HOME;
        case "END";      return xx Key.END;
        case "PAGEDOWN"; return xx Key.PAGE_DOWN;
        case "PAGEUP";   return xx Key.PAGE_UP;
        case "BACKSPACE";return xx Key.BACKSPACE;
        case "F5";       return xx Key.F5;
    }
    return 0;
}
