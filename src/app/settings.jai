// Preferences (plain text, %APPDATA%/Uppies/settings.ini) and the access
// token (DPAPI-encrypted, %APPDATA%/Uppies/token.bin: readable only by this
// Windows user on this machine). The synced data itself is in
// %APPDATA%/Uppies/store.uppies (see up/store_file.jai).

History_Depth :: enum u8 { ALL; TWO_YEARS; ONE_YEAR; NINETY_DAYS; }
HISTORY_LABELS :: string.["All history", "2 years", "1 year", "90 days"];

AUTO_REFRESH_MINUTES :: int.[0, 1, 5, 15, 60];
AUTO_REFRESH_LABELS  :: string.["Off", "1 min", "5 min", "15 min", "1 hour"];

Settings :: struct {
    auto_refresh: int = 2;          // Index into AUTO_REFRESH_MINUTES.
    history: History_Depth = .ALL;
    exclude_transfers := true;      // Moves between your own accounts aren't income or spending.
    reduce_motion := false;
    vsync := true;
    remember_token := true;
    sample_data := false;           // Last session used sample data.
    store_locally := true;          // Keep an encrypted copy of the data on this PC.
}

settings: Settings;

settings_load :: () {
    if !persist_enabled return;
    path := tprint("%/settings.ini", platform_app_data_dir());
    text, ok := read_entire_file(path,, temp);
    if !ok return;
    for line: split(text, "\n",, temp) {
        found, key, value := split_from_left(trim(line), "=");
        if !found continue;
        key = trim(key);
        value = trim(value);
        number, number_ok := string_to_int(value);
        flag := value == "true" || value == "1";
        if key == {
            case "auto_refresh";      if number_ok settings.auto_refresh = clamp(number, 0, AUTO_REFRESH_MINUTES.count - 1);
            case "history";           if number_ok settings.history = cast(History_Depth) clamp(number, 0, 3);
            case "exclude_transfers"; settings.exclude_transfers = flag;
            case "reduce_motion";     settings.reduce_motion = flag;
            case "vsync";             settings.vsync = flag;
            case "remember_token";    settings.remember_token = flag;
            case "sample_data";       settings.sample_data = flag;
            case "store_locally";     settings.store_locally = flag;
        }
    }
}

settings_save :: () {
    if !persist_enabled return;
    builder: String_Builder;
    builder.allocator = temp;
    print_to_builder(*builder, "auto_refresh=%\n", settings.auto_refresh);
    print_to_builder(*builder, "history=%\n", cast(int) settings.history);
    print_to_builder(*builder, "exclude_transfers=%\n", settings.exclude_transfers);
    print_to_builder(*builder, "reduce_motion=%\n", settings.reduce_motion);
    print_to_builder(*builder, "vsync=%\n", settings.vsync);
    print_to_builder(*builder, "remember_token=%\n", settings.remember_token);
    print_to_builder(*builder, "sample_data=%\n", settings.sample_data);
    print_to_builder(*builder, "store_locally=%\n", settings.store_locally);
    write_entire_file(tprint("%/settings.ini", platform_app_data_dir()), *builder);
}

token_path :: () -> string { return tprint("%/token.bin", platform_app_data_dir()); }

// The saved token, if there is one and it decrypts.
token_load :: () -> string, bool {
    if !persist_enabled return "", false;
    cipher, ok := read_entire_file(token_path(),, temp);
    if !ok || !cipher.count return "", false;
    plain, decrypted := platform_unprotect(cipher);
    if !decrypted return "", false;
    return plain, true;
}

token_save :: (token: string) -> bool {
    if !persist_enabled return false;
    cipher, ok := platform_protect(token);
    if !ok return false;
    defer free(cipher);
    return write_entire_file(token_path(), cipher);
}

token_forget :: () {
    if !persist_enabled return;
    path := token_path();
    if file_exists(path) {
        // Overwrite before deleting: the ciphertext is useless elsewhere, but tidy.
        old, ok := read_entire_file(path,, temp);
        if ok && old.count {
            zeros := NewArray(old.count, u8,, temp);
            write_entire_file(path, zeros.data, zeros.count);
        }
        file_delete(path);
    }
}

// What the user sees of a token: its prefix and last four characters.
mask_token :: (token: string) -> string {
    if token.count <= 12 return "••••";
    prefix := token;
    // "up:yeah:" keeps its scheme visible.
    colon := 0;
    count := 0;
    for 0..token.count - 1 if token[it] == #char ":" { count += 1; if count == 2 { colon = it + 1; break; } }
    prefix.count = colon;
    return tprint("%••••••••%", prefix, slice(token, token.count - 4, 4));
}
