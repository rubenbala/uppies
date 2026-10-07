// Local data: keeps the store saved on this machine (up/store_file.jai) so the app
// opens instantly with everything it had, then catches up with Up.
//
//   open    sync_start reads the file before anything is asked of Up. It only
//           opens with the same token it was saved with (and the same OS
//           user); anything else is deleted and downloaded fresh.
//   save    whenever the store has changed and then been quiet for a moment,
//           at least every 15 s during a long download, and at exit. The
//           work happens on the store file's writer thread.
//   delete  Settings > Data, on disconnect, and when the setting is off.
//
// Sample data isn't stored (it is generated fresh each run) unless the
// -cache-demo flag asks for it, which tests use.

Local_Data :: struct {
    opened:       bool;      // This session started from the saved file.
    seen_version: u64;
    dirty:        bool;
    changed_at:   float64;   // First change not yet saved (ui clock).
    last_change:  float64;   // Most recent change.
    saved_at:     float64;
    cache_demo:   bool;      // -cache-demo
}

local_data: Local_Data;

QUIET_BEFORE_SAVE :: 1.5;   // Seconds without changes.
MAX_UNSAVED       :: 15.0;  // Seconds of continuous change (a long download).

local_data_enabled :: () -> bool {
    if !persist_enabled || !settings.store_locally return false;
    if sync.demo && !local_data.cache_demo return false;
    return true;
}

// Fills the empty store from the file, if there is one for this token.
// Returns true when the app can show it straight away.
local_data_open :: (token: string) -> bool {
    cache_demo := local_data.cache_demo;
    local_data = .{cache_demo = cache_demo};
    if !local_data_enabled() return false;

    start := seconds_since_init();
    meta, status := store_file_load(*store, store_secret());
    if status == .MISSING return false;
    if status != .OK {
        // Another token or user, damaged, or from an incompatible version:
        // it can never be used, so don't keep it around.
        log("Local data not used (%); downloading everything again.\n", status);
        store_file_delete();
        return false;
    }
    if meta.history != cast(u8) settings.history || !store.accounts.count {
        // Saved with another "History to load" setting: start over with this one.
        store_reset(*store);
        store_file_delete();
        return false;
    }
    log("Opened local data: % transactions in % ms.\n", store.transactions.count, formatFloat((seconds_since_init() - start) * 1000, trailing_width = 1));
    sync_restore(meta);
    local_data.opened = true;
    local_data.seen_version = store.version;
    return true;
}

// Each frame, after sync_update.
local_data_update :: () {
    if !local_data_enabled() return;
    if !worth_saving() return;
    now := ui.time;
    if store.version != local_data.seen_version {
        if !local_data.dirty local_data.changed_at = now;
        local_data.seen_version = store.version;
        local_data.dirty = true;
        local_data.last_change = now;
    }
    if !local_data.dirty return;
    quiet := now - local_data.last_change >= QUIET_BEFORE_SAVE;
    overdue := now - local_data.changed_at >= MAX_UNSAVED;
    if quiet || overdue local_data_save();
    else ui_wake_at(local_data.last_change + QUIET_BEFORE_SAVE);
}

local_data_save :: () {
    if !local_data_enabled() || !worth_saving() return;
    store_file_save(*store, sync_meta(), store_secret());
    local_data.dirty = false;
    local_data.saved_at = ui.time;
    local_data.seen_version = store.version;
}

// Deletes everything stored on this PC. The data in memory is untouched.
local_data_delete :: () {
    store_file_delete();
    local_data.dirty = false;
    local_data.opened = false;
}

// At exit: save what changed and wait for the write to finish.
local_data_shutdown :: () {
    if local_data.dirty || store.version != local_data.seen_version local_data_save();
    store_file_flush();
    if local_data_enabled() && worth_saving() {
        log("Local data at exit: % transactions (% unique), history %.\n", store.transactions.count, store.txn_lookup.count,
            ifx sync.history_complete then "complete" else "partial");
    }
}

#scope_file

// Something complete enough to reopen from: accounts and at least the newest
// page of transactions, or a finished (or resumed) sync.
worth_saving :: () -> bool {
    if !store.accounts.count return false;
    if sync.phase == .READY return true;
    return sync.phase == .LOADING && sync.pages > 0;
}

store_secret :: () -> string {
    return ifx sync.demo then "up:demo:sample" else sync.token;
}
