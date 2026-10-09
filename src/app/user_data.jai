// What the customer told us, in user.bin: sealed like token.bin (only this
// user on this machine can read it), and not part of store.uppies, which is
// thrown away and downloaded again whenever the token changes. A line each:
//
//   hide <id in hex>       a recurring series that isn't recurring
//   exclude <account id>   an account left out of totals
//
// Lines a build doesn't know are skipped, so older builds read newer files.

User_Data :: struct {
    excluded_ids: [..] string;   // Up account ids (they don't change).
    excluded_version: u64;
}

user_data: User_Data;

user_data_load :: () {
    if !persist_enabled { user_data_parse(""); return; }
    cipher, ok := read_entire_file(user_data_path(),, temp);
    plain: string;
    opened: bool;
    if ok && cipher.count plain, opened = platform_unprotect(cipher, USER_DATA_ENTROPY);
    user_data_parse(ifx opened then plain else "");
    if opened free(plain);
}

user_data_save :: () {
    if !persist_enabled return;
    cipher, ok := platform_protect(user_data_text(), USER_DATA_ENTROPY);
    if !ok { app_toast(.ERROR, "Couldn't save that change on this device."); return; }
    defer free(cipher);
    write_entire_file(user_data_path(), cipher);
}

// Replaces what we were told with the lines in `plain`.
user_data_parse :: (plain: string) {
    recurring.hidden.count = 0;
    recurring.hidden_version += 1;
    for user_data.excluded_ids free(it);
    user_data.excluded_ids.count = 0;
    user_data.excluded_version += 1;
    for line: split(plain, "\n",, temp) {
        found, command, value := split_from_left(trim(line), " ");
        if !found continue;
        value = trim(value);
        if command == {
            case "hide";
                id, id_ok := string_to_int(value, 16, u64);
                if id_ok && !array_find(recurring.hidden, id) array_add(*recurring.hidden, id);
            case "exclude";
                if value.count && !array_find(user_data.excluded_ids, value) array_add(*user_data.excluded_ids, copy_string(value));
        }
    }
}

// The lines user.bin holds (temporary storage).
user_data_text :: () -> string {
    builder: String_Builder;
    builder.allocator = temp;
    for recurring.hidden print_to_builder(*builder, "hide %\n", formatInt(it, base = 16));
    for user_data.excluded_ids print_to_builder(*builder, "exclude %\n", it);
    return builder_to_string(*builder,, temp);
}

// Leaves an account out of totals, or counts it again, and saves that.
account_set_excluded :: (account: int, excluded: bool) {
    if account < 0 || account >= store.accounts.count return;
    id := store.accounts[account].id;
    found, index := array_find(user_data.excluded_ids, id);
    if excluded == found return;
    if excluded array_add(*user_data.excluded_ids, copy_string(id));
    else {
        free(user_data.excluded_ids[index]);
        array_ordered_remove_by_index(*user_data.excluded_ids, index);
    }
    user_data.excluded_version += 1;
    user_data_save();
}

#scope_file

USER_DATA_ENTROPY :: "user-data";

user_data_path :: () -> string { return tprint("%/user.bin", platform_app_data_dir()); }
