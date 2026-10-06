// Sync: turns API replies into the store, and decides what to ask for next.
//
//   connect   GET /util/ping validates the token.
//   load      accounts, categories and tags, then the whole transaction
//             history, newest first, a page of 100 at a time. The UI works
//             from the first page on; later pages fill in the past.
//   refresh   balances, plus every transaction created since a little before
//             the oldest one still held (or the last few days). That window
//             replaces what the store had for it, so settlements, edits and
//             declined holds all come through.
//
// With local data (local_data.jai) the app opens on what it saved last time
// and, once Up answers the ping, catches up instead of loading:
//
//   catch up  categories, tags, balances, and the same kind of window going
//             back CATCH_UP_DAYS (or to the last sync, if older): new
//             transactions, settlements, declined holds and recent edits.
//   resume    a history download that was cut short continues from the
//             oldest transaction it reached (filter[until]).
//   full check  Up has no feed of changes, so an edit to an old transaction
//             (recategorised in the Up app, say) only shows up by reading it
//             again. Every FULL_CHECK_DAYS the whole history is read again in
//             the background, and replaces the store in one step.
//
// Each connection is a generation: replies to an older one are dropped.
// Transient failures (network, 429, 5xx) retry with backoff; a 401 stops
// everything and asks for a new token. Writes (category, tags) apply at
// once and are rolled back if the API refuses them.

Sync_Phase :: enum u8 { OFFLINE; CONNECTING; LOADING; READY; }
Refresh_Kind :: enum u8 { RECENT; CATCH_UP; FULL; }

CATCH_UP_DAYS   :: 45;
FULL_CHECK_DAYS :: 7;
Load_State :: enum u8 { IDLE; LOADING; LOADED; FAILED; }

Sync :: struct {
    phase: Sync_Phase;
    generation: u32;
    demo: bool;
    token: string;

    connect_error: string;

    accounts_done:   bool;
    categories_done: bool;
    tags_done:       bool;
    pages:           int;
    history_complete: bool;
    load_started:    float64;
    earliest_account_utc: s64;
    oldest_loaded_utc:    s64;

    refreshing:      bool;
    refresh_batch:   [..] Transaction;
    refresh_window:  s64;
    refresh_waiting: int;
    refresh_new:     int;
    refresh_manual:  bool;
    refresh_kind:    Refresh_Kind;
    edited_during_refresh: [..] string;   // Transactions written to while a refresh was out.

    connected:       bool;     // Up answered the ping, this generation.
    from_saved:      bool;     // Showing local data that hasn't caught up with Up yet.
    catch_up_at:     float64;  // Retry time for a failed catch-up (ui clock).
    loaded_history:  History_Depth;        // The depth the store's history was loaded with.
    last_full_check_utc: s64;

    last_sync_utc:  s64;
    last_sync_time: float64;
    next_auto:      float64;

    error:          string;
    error_status:   s32;
    retry_at:       float64;
    retry_attempts: int;
    auth_failed:    bool;

    webhooks:       [..] Webhook;
    webhooks_state: Load_State;
    webhooks_error: string;
    logs:           [..] Webhook_Log;
    logs_for:       string;
    logs_next:      string;
    logs_state:     Load_State;
    new_secret:     string;
    new_secret_for: string;
    webhook_busy:   int;

    pending_writes: int;

    // Writes made together (to several transactions at once) report in one
    // toast, once the last of them is answered.
    batches:    [..] Write_Batch;
    batch_open: u32;   // Writes submitted now join this batch.
    batch_next: u32;
}

Write_Batch :: struct {
    id:      u32;
    total:   int;
    pending: int;
    failed:  int;
    closed:  bool;     // Every write has been submitted.
    done:    string;   // Heap: the toast when they all succeed.
    failure: string;   // Heap: how the toast starts when some fail.
    error:   string;   // Heap: why the first one failed.
}

sync: Sync;

sync_start :: (token: string, demo: bool) {
    sync_reset_data();
    free(sync.token);
    sync.token = copy_string(token);
    sync.demo = demo;
    api_set_demo(demo);
    api_set_token(ifx demo then "up:demo:sample" else token);
    sync.generation += 1;
    sync.phase = .CONNECTING;
    sync.connected = false;
    set_string(*sync.connect_error, "");
    sync.auth_failed = false;
    // Show what was saved last time straight away; the ping confirms the
    // token and then the app catches up with Up.
    if local_data_open(token) {
        sync.phase = .READY;
        sync.from_saved = true;
        app_on_connected();
    }
    api_submit(.PING, "GET", "/util/ping", generation = sync.generation, urgent = true);
}

// Sync state as saved with the local data, and back.
sync_meta :: () -> Store_File_Meta {
    m: Store_File_Meta;
    m.saved_utc           = platform_local_time().utc_seconds;
    m.last_sync_utc       = sync.last_sync_utc;
    m.last_full_check_utc = sync.last_full_check_utc;
    m.history             = cast(u8) sync.loaded_history;
    m.history_complete    = sync.history_complete;
    m.oldest_loaded_utc   = sync.oldest_loaded_utc;
    return m;
}

sync_restore :: (m: Store_File_Meta) {
    sync.last_sync_utc       = m.last_sync_utc;
    sync.last_full_check_utc = m.last_full_check_utc;
    sync.loaded_history      = cast(History_Depth) m.history;
    sync.history_complete    = m.history_complete;
    sync.oldest_loaded_utc   = m.oldest_loaded_utc;
    if !sync.oldest_loaded_utc && store.transactions.count sync.oldest_loaded_utc = store.transactions[store.transactions.count - 1].created.utc;
    sync.accounts_done   = true;
    sync.categories_done = true;
    sync.tags_done       = true;
    sync.pages           = 1;
    sync.earliest_account_utc = platform_local_time().utc_seconds;
    for store.accounts sync.earliest_account_utc = min(sync.earliest_account_utc, it.created.utc);
}

sync_disconnect :: () {
    sync.generation += 1;   // Anything still in flight is ignored.
    local_data_delete();
    sync_reset_data();
    sync.phase = .OFFLINE;
    sync.connected = false;
    free(sync.token);
    sync.token = "";
    api_set_token("");
}

// Forgets everything loaded (and saved) and loads it all again.
sync_reload_all :: () {
    if sync.phase == .OFFLINE || sync.phase == .CONNECTING return;
    local_data_delete();
    sync.generation += 1;
    sync_reset_data();
    sync.connected = true;   // Still the same, already verified token.
    begin_load();
}

sync_refresh :: (manual := false) {
    if sync.phase != .READY || sync.refreshing || sync.auth_failed return;
    if sync.from_saved {
        // Still to catch up: that comes first, once Up has answered.
        if sync.connected start_refresh(.CATCH_UP, manual);
        return;
    }
    if !store.transactions.count { sync_reload_all(); return; }
    start_refresh(.RECENT, manual);
}

sync_is_busy :: () -> bool {
    return sync.phase == .CONNECTING || (sync.phase == .LOADING) || sync.refreshing || sync.from_saved;
}

// Seconds until the next full check is due (negative: overdue).
sync_full_check_due_in :: () -> s64 {
    return sync.last_full_check_utc + FULL_CHECK_DAYS * SECONDS_PER_DAY - platform_local_time().utc_seconds;
}

// Reads the whole history again now (Settings).
sync_full_check :: () {
    if sync.phase != .READY || sync.refreshing || sync.auth_failed || sync.from_saved || !sync.history_complete return;
    start_refresh(.FULL, true);
}

// 0..1 through the history load, estimated from how far back it has got.
sync_load_progress :: () -> float {
    if sync.history_complete return 1;
    if !sync.accounts_done return 0.02;
    now := platform_local_time().utc_seconds;
    span := max(now - sync.earliest_account_utc, 1);
    if !sync.pages return 0.05;
    return clamp(cast(float) (now - sync.oldest_loaded_utc) / cast(float) span, 0.05, 0.98);
}

//
// Writes.
//

sync_set_category :: (txn_index: s32, category: s32) {
    if txn_index < 0 || txn_index >= store.transactions.count return;
    t := *store.transactions[txn_index];
    previous := t.category;
    if previous == category return;
    body := ifx category >= 0 then tprint("{\"data\":{\"type\":\"categories\",\"id\":\"%\"}}", store.categories[category].id) else "{\"data\":null}";
    store_set_category(*store, txn_index, category);
    note_edit(t.id);
    sync.pending_writes += 1;
    api_submit(.SET_CATEGORY, "PATCH", tprint("/transactions/%/relationships/category", t.id), body, ref = t.id, arg = ifx previous >= 0 then store.categories[previous].id else "", arg_int = category, urgent = true, batch = join_batch());
}

sync_add_tag :: (txn_index: s32, label: string) {
    if txn_index < 0 || txn_index >= store.transactions.count || !label.count return;
    t := *store.transactions[txn_index];
    if t.tag_count >= MAX_TAGS { app_toast(.ERROR, "A transaction can have at most 6 tags."); return; }
    tag := store_intern_tag(*store, label);
    if txn_has_tag(t, tag) return;
    store_add_tag(*store, txn_index, tag);
    note_edit(t.id);
    sync.pending_writes += 1;
    body := tprint("{\"data\":[{\"type\":\"tags\",\"id\":\"%\"}]}", json_escape(label));
    api_submit(.ADD_TAG, "POST", tprint("/transactions/%/relationships/tags", t.id), body, ref = t.id, arg = label, urgent = true, batch = join_batch());
}

sync_remove_tag :: (txn_index: s32, tag: s32) {
    if txn_index < 0 || txn_index >= store.transactions.count || tag < 0 return;
    t := *store.transactions[txn_index];
    label := store.tags[tag].label;
    store_remove_tag(*store, txn_index, tag);
    note_edit(t.id);
    sync.pending_writes += 1;
    body := tprint("{\"data\":[{\"type\":\"tags\",\"id\":\"%\"}]}", json_escape(label));
    api_submit(.REMOVE_TAG, "DELETE", tprint("/transactions/%/relationships/tags", t.id), body, ref = t.id, arg = label, urgent = true, batch = join_batch());
}

// Groups the writes made until sync_batch_end into one toast, shown when the
// last of them is answered: `done` when they all succeed, otherwise `failure`
// with how many failed and why. (On their own, writes only report failures.)
sync_batch_begin :: () {
    sync.batch_next += 1;
    b := array_add(*sync.batches);
    b.id = sync.batch_next;
    sync.batch_open = b.id;
}

sync_batch_end :: (done: string, failure: string) {
    b, index := find_batch(sync.batch_open);
    sync.batch_open = 0;
    if !b return;
    b.closed = true;
    b.done = copy_string(done);
    b.failure = copy_string(failure);
    finish_batch(index);
}

sync_open_attachment :: (id: string) {
    api_submit(.ATTACHMENT, "GET", tprint("/attachments/%", id), ref = id, urgent = true);
}

//
// Webhooks.
//

sync_load_webhooks :: () {
    if sync.phase != .READY || sync.webhooks_state == .LOADING return;
    sync.webhooks_state = .LOADING;
    api_submit(.WEBHOOKS, "GET", tprint("/webhooks?%", query_param("page[size]", "50")), generation = sync.generation);
}

sync_create_webhook :: (url: string, description: string) {
    body := ifx description.count
        then tprint("{\"data\":{\"attributes\":{\"url\":\"%\",\"description\":\"%\"}}}", json_escape(url), json_escape(description))
        else tprint("{\"data\":{\"attributes\":{\"url\":\"%\"}}}", json_escape(url));
    sync.webhook_busy += 1;
    api_submit(.WEBHOOK_CREATE, "POST", "/webhooks", body, generation = sync.generation, urgent = true);
}

sync_delete_webhook :: (id: string) {
    sync.webhook_busy += 1;
    api_submit(.WEBHOOK_DELETE, "DELETE", tprint("/webhooks/%", id), generation = sync.generation, ref = id, urgent = true);
}

sync_ping_webhook :: (id: string) {
    sync.webhook_busy += 1;
    api_submit(.WEBHOOK_PING, "POST", tprint("/webhooks/%/ping", id), generation = sync.generation, ref = id, urgent = true);
}

sync_load_logs :: (webhook_id: string, more := false) {
    if more {
        if !sync.logs_next.count || sync.logs_state == .LOADING return;
        sync.logs_state = .LOADING;
        api_submit(.WEBHOOK_LOGS, "GET", sync.logs_next, generation = sync.generation, ref = webhook_id, arg = "more");
        return;
    }
    for * sync.logs free_webhook_log(it);
    sync.logs.count = 0;
    set_string(*sync.logs_for, webhook_id);
    set_string(*sync.logs_next, "");
    sync.logs_state = .LOADING;
    api_submit(.WEBHOOK_LOGS, "GET", tprint("/webhooks/%/logs?%", webhook_id, query_param("page[size]", "50")), generation = sync.generation, ref = webhook_id);
}

//
// The frame's work: replies and timers.
//

sync_update :: () {
    for req: api_take_completed() {
        handle_reply(req);
        api_free(req);
    }

    now := ui.time;
    if sync.phase == .READY && !sync.refreshing && !sync.auth_failed {
        minutes := AUTO_REFRESH_MINUTES[settings.auto_refresh];
        if minutes > 0 {
            if sync.next_auto == 0 sync.next_auto = now + minutes * 60;
            if now >= sync.next_auto sync_refresh();
            else ui_wake_at(sync.next_auto);
        }
    }
    if sync.catch_up_at > 0 && sync.from_saved && sync.connected && !sync.refreshing && !sync.auth_failed {
        if now >= sync.catch_up_at {
            sync.catch_up_at = 0;
            start_refresh(.CATCH_UP);
        } else {
            ui_wake_at(sync.catch_up_at);
        }
    }
    if sync.retry_at > 0 {
        if now >= sync.retry_at {
            sync.retry_at = 0;
            retry_pending();
        } else {
            ui_wake_at(sync.retry_at);
        }
    }
}

set_string :: (s: *string, value: string) {
    free(s.*);
    s.* = copy_string(value);
}

#scope_file

// Failed requests waiting for their retry.
Retry :: struct {
    kind: Api_Kind;
    method: string;
    path: string;
    arg: string;
    window_since: s64;
    generation: u32;
}
retries: [..] Retry;

sync_reset_data :: () {
    store_reset(*store);
    sync.accounts_done = false;
    sync.categories_done = false;
    sync.tags_done = false;
    sync.pages = 0;
    sync.history_complete = false;
    sync.refreshing = false;
    for * sync.refresh_batch free_transaction(it);
    sync.refresh_batch.count = 0;
    clear_edits();
    sync.from_saved = false;
    sync.catch_up_at = 0;
    sync.last_full_check_utc = 0;
    sync.oldest_loaded_utc = 0;
    sync.last_sync_utc = 0;
    sync.next_auto = 0;
    set_string(*sync.error, "");
    sync.error_status = 0;
    sync.retry_at = 0;
    sync.retry_attempts = 0;
    for retries { free(it.method); free(it.path); free(it.arg); }
    retries.count = 0;
    for * sync.webhooks free_webhook(it);
    sync.webhooks.count = 0;
    sync.webhooks_state = .IDLE;
    for * sync.logs free_webhook_log(it);
    sync.logs.count = 0;
    sync.logs_state = .IDLE;
    set_string(*sync.logs_for, "");
    set_string(*sync.logs_next, "");
    set_string(*sync.new_secret, "");
    set_string(*sync.new_secret_for, "");
    sync.pending_writes = 0;
    sync.webhook_busy = 0;
}

begin_load :: () {
    sync.phase = .LOADING;
    sync.loaded_history = settings.history;
    sync.load_started = ui.time;
    g := sync.generation;
    api_submit(.ACCOUNTS,   "GET", tprint("/accounts?%", query_param("page[size]", "100")), generation = g);
    api_submit(.CATEGORIES, "GET", "/categories", generation = g);
    api_submit(.TAGS,       "GET", tprint("/tags?%", query_param("page[size]", "100")), generation = g);
}

history_since :: () -> s64 {
    days: s64;
    if settings.history == {
        case .ALL;         return -1;
        case .TWO_YEARS;   days = 730;
        case .ONE_YEAR;    days = 365;
        case .NINETY_DAYS; days = 90;
    }
    return platform_local_time().utc_seconds - days * SECONDS_PER_DAY;
}

// The history, newest first. `until`: only what was created before it (to
// continue a download that was cut short).
begin_transactions :: (until: s64 = -1) {
    path := tprint("/transactions?%", query_param("page[size]", tprint("%", PAGE_SIZE)));
    since := history_since();
    if since >= 0 path = tprint("%&%", path, query_param("filter[since]", format_rfc3339_utc(since)));
    if until >= 0 path = tprint("%&%", path, query_param("filter[until]", format_rfc3339_utc(until)));
    api_submit(.TRANSACTIONS, "GET", path, generation = sync.generation);
}

start_refresh :: (kind: Refresh_Kind, manual := false) {
    if sync.refreshing return;
    now := platform_local_time().utc_seconds;

    // RECENT and CATCH_UP: back to just before the oldest held transaction,
    // at least three days, and for a catch-up at least CATCH_UP_DAYS and
    // the last sync. FULL: everything the history setting covers.
    window: s64 = 0;
    if kind == .FULL {
        window = max(history_since(), 0);
    } else {
        window = now - 3 * SECONDS_PER_DAY;
        if store.transactions.count window = min(window, store.transactions[0].created.utc - 3 * SECONDS_PER_DAY);
        for store.transactions if it.status == .HELD window = min(window, it.created.utc - 60);
        if kind == .CATCH_UP {
            window = min(window, now - CATCH_UP_DAYS * SECONDS_PER_DAY);
            if sync.last_sync_utc window = min(window, sync.last_sync_utc - 3 * SECONDS_PER_DAY);
        }
        // Never reach past what the history covers: that would look like
        // transactions disappearing.
        window = max(window, max(history_since(), 0));
        if !sync.history_complete window = max(window, sync.oldest_loaded_utc);
    }

    sync.refreshing = true;
    sync.refresh_kind = kind;
    sync.refresh_manual = manual;
    sync.refresh_window = window;
    sync.refresh_new = 0;
    for * sync.refresh_batch free_transaction(it);
    sync.refresh_batch.count = 0;
    clear_edits();
    sync.refresh_waiting = 2;
    g := sync.generation;
    api_submit(.ACCOUNTS, "GET", tprint("/accounts?%", query_param("page[size]", "100")), generation = g, arg = "refresh");
    path := tprint("/transactions?%", query_param("page[size]", tprint("%", PAGE_SIZE)));
    if window > 0 path = tprint("%&%", path, query_param("filter[since]", format_rfc3339_utc(window)));
    api_submit(.TRANSACTIONS, "GET", path, generation = g, arg = "refresh", window_since = window);
}

// A full check is due when the history is complete and hasn't been read
// end to end for FULL_CHECK_DAYS.
continue_after_refresh :: () {
    if sync.from_saved || sync.auth_failed return;
    if !sync.history_complete {
        // Pick up a download that was cut short where it stopped.
        sync.phase = .LOADING;
        sync.load_started = ui.time;
        begin_transactions(sync.oldest_loaded_utc + 1);
        return;
    }
    if sync_full_check_due_in() <= 0 start_refresh(.FULL);
}

note_edit :: (id: string) {
    if !sync.refreshing return;
    for sync.edited_during_refresh if it == id return;
    array_add(*sync.edited_during_refresh, copy_string(id));
}

clear_edits :: () {
    for sync.edited_during_refresh free(it);
    sync.edited_during_refresh.count = 0;
}

// What the refresh read may predate an edit made since it started: keep the
// local category and tags for those (the write itself is on its way to Up).
keep_local_edits :: (batch: [] Transaction) {
    if !sync.edited_during_refresh.count return;
    for * t: batch {
        edited := false;
        for sync.edited_during_refresh if it == t.id { edited = true; break; }
        if !edited continue;
        index := store_find_transaction(*store, t.id);
        if index < 0 continue;
        local := *store.transactions[index];
        t.category        = local.category;
        t.parent_category = local.parent_category;
        t.tags            = local.tags;
        t.tag_count       = local.tag_count;
    }
}

finish_sync :: () {
    lt := platform_local_time();
    sync.last_sync_utc = lt.utc_seconds;
    sync.last_sync_time = ui.time;
    minutes := AUTO_REFRESH_MINUTES[settings.auto_refresh];
    sync.next_auto = ifx minutes > 0 then ui.time + minutes * 60 else 0;
    set_string(*sync.error, "");
    sync.error_status = 0;
    sync.retry_attempts = 0;
}

transient :: (req: *Api_Request) -> bool {
    s := req.result.status;
    return s == 0 || s == 429 || s >= 500;
}

// Records a failure; transient ones retry after a backoff.
fail :: (req: *Api_Request, what: string) {
    message := api_error_message(req);
    set_string(*sync.error, tprint("%: %", what, message));
    sync.error_status = req.result.status;
    if req.result.status == 401 {
        sync.auth_failed = true;
        app_toast(.ERROR, "Up rejected the access token. Reconnect in Settings.");
        return;
    }
    if transient(req) {
        delay := cast(float64) min(5 * (1 << min(sync.retry_attempts, 4)), 120);
        if req.result.retry_after > 0 delay = max(delay, cast(float64) req.result.retry_after);
        sync.retry_attempts += 1;
        sync.retry_at = ui.time + delay;
        r := array_add(*retries);
        r.kind = req.kind;
        r.method = copy_string(req.method);
        r.path = copy_string(req.path);
        r.arg = copy_string(req.arg);
        r.window_since = req.window_since;
        r.generation = req.generation;
    }
}

retry_pending :: () {
    pending: [..] Retry;
    pending.allocator = temp;
    for retries array_add(*pending, it);
    retries.count = 0;
    for pending {
        if it.generation == sync.generation {
            api_submit(it.kind, it.method, tprint("https://%1%2", API_HOST, it.path), generation = it.generation, arg = it.arg, window_since = it.window_since);
        }
        free(it.method); free(it.path); free(it.arg);
    }
}

handle_reply :: (req: *Api_Request) {
    sync_kind := req.kind == .PING || req.kind == .ACCOUNTS || req.kind == .CATEGORIES || req.kind == .TAGS || req.kind == .TRANSACTIONS
              || req.kind == .WEBHOOKS || req.kind == .WEBHOOK_LOGS || req.kind == .WEBHOOK_CREATE || req.kind == .WEBHOOK_DELETE || req.kind == .WEBHOOK_PING;
    if sync_kind && req.generation != sync.generation return;

    ok := api_ok(req);
    if req.kind == {
        case .PING;
            if req.arg == "test" {
                if ok app_toast(.SUCCESS, tprint("Up answered in % ms.", cast(int) (req.elapsed_ms + 0.5)));
                else app_toast(.ERROR, tprint("Connection test failed: %", api_error_message(req)));
                return;
            }
            if !ok {
                if sync.from_saved {
                    // Keep showing the saved data: offline, or the token was
                    // revoked (which Settings explains). Transient failures retry.
                    fail(req, "Connecting to Up");
                    return;
                }
                message := api_error_message(req);
                if req.result.status == 401 message = "Up didn't accept that token (401). Check it was copied in full and hasn't been revoked.";
                set_string(*sync.connect_error, message);
                sync.phase = .OFFLINE;
                return;
            }
            set_string(*sync.connect_error, "");
            set_string(*sync.error, "");
            sync.retry_attempts = 0;
            sync.connected = true;
            if sync.from_saved {
                // Categories and tags first, so the catch-up resolves against them.
                api_submit(.CATEGORIES, "GET", "/categories", generation = sync.generation, arg = "catch-up");
                api_submit(.TAGS, "GET", tprint("/tags?%", query_param("page[size]", "100")), generation = sync.generation);
                return;
            }
            app_on_connected();
            begin_load();

        case .ACCOUNTS;
            if !ok {
                if req.arg == "refresh" refresh_failed(req); else fail(req, "Loading accounts");
                return;
            }
            doc, parsed := json_parse(req.result.body,, temp);
            if !parsed { set_string(*sync.error, "Accounts: the response could not be read."); return; }
            incoming: [..] Account;
            incoming.allocator = temp;
            for * json_array(json_get(*doc, "data")) array_add(*incoming, parse_account(it));
            store_merge_accounts(*store, incoming);
            next := json_string(json_at(*doc, "links", "next"));
            if next.count {
                api_submit(.ACCOUNTS, "GET", next, generation = req.generation, arg = req.arg);
                return;
            }
            if req.arg == "refresh" {
                refresh_part_done();
                return;
            }
            sync.accounts_done = true;
            sync.earliest_account_utc = platform_local_time().utc_seconds;
            for store.accounts sync.earliest_account_utc = min(sync.earliest_account_utc, it.created.utc);
            maybe_start_transactions();

        case .CATEGORIES;
            if !ok { fail(req, "Loading categories"); return; }
            doc, parsed := json_parse(req.result.body,, temp);
            if !parsed return;
            incoming: [..] Category;
            incoming.allocator = temp;
            for * json_array(json_get(*doc, "data")) array_add(*incoming, parse_category(it));
            store_merge_categories(*store, incoming);
            sync.categories_done = true;
            if req.arg == "catch-up" { start_refresh(.CATCH_UP); return; }
            maybe_start_transactions();

        case .TAGS;
            if !ok { fail(req, "Loading tags"); return; }
            doc, parsed := json_parse(req.result.body,, temp);
            if !parsed return;
            for * json_array(json_get(*doc, "data")) store_intern_tag(*store, json_string(json_get(it, "id")));
            next := json_string(json_at(*doc, "links", "next"));
            if next.count api_submit(.TAGS, "GET", next, generation = req.generation);
            else sync.tags_done = true;

        case .TRANSACTIONS;
            if !ok {
                if req.arg == "refresh" refresh_failed(req); else fail(req, "Loading transactions");
                return;
            }
            doc, parsed := json_parse(req.result.body,, temp);
            if !parsed {
                set_string(*sync.error, "Transactions: the response could not be read.");
                if req.arg == "refresh" sync.refreshing = false;
                return;
            }
            batch: [..] Transaction;
            batch.allocator = temp;
            for * json_array(json_get(*doc, "data")) array_add(*batch, parse_transaction(it, *store));
            next := json_string(json_at(*doc, "links", "next"));

            if req.arg == "refresh" {
                for batch array_add(*sync.refresh_batch, it);
                if next.count {
                    api_submit(.TRANSACTIONS, "GET", next, generation = req.generation, arg = "refresh", window_since = req.window_since);
                } else {
                    // The window is complete: merge it as one truth.
                    known := 0;
                    for sync.refresh_batch if store_find_transaction(*store, it.id) >= 0 known += 1;
                    sync.refresh_new = sync.refresh_batch.count - known;
                    keep_local_edits(sync.refresh_batch);
                    store_merge_transactions(*store, sync.refresh_batch, ui.time, req.window_since);
                    sync.refresh_batch.count = 0;   // The store owns them now.
                    refresh_part_done();
                }
                return;
            }

            store_merge_transactions(*store, batch, -1000);   // History isn't "new": no highlight.
            sync.pages += 1;
            if batch.count sync.oldest_loaded_utc = batch[batch.count - 1].created.utc;
            if next.count {
                api_submit(.TRANSACTIONS, "GET", next, generation = req.generation);
            } else {
                sync.history_complete = true;
                sync.phase = .READY;
                // Every transaction was just read from Up: that's a full check.
                sync.last_full_check_utc = platform_local_time().utc_seconds;
                finish_sync();
            }

        case .SET_CATEGORY;
            sync.pending_writes -= 1;
            if !ok {
                // Put it back.
                index := store_find_transaction(*store, req.ref);
                if index >= 0 store_set_category(*store, index, store_find_category(*store, req.arg));
            }
            if !batch_reply(req, ok) && !ok app_toast(.ERROR, tprint("Category not changed: %", api_error_message(req)));

        case .ADD_TAG;
            sync.pending_writes -= 1;
            if !ok {
                index := store_find_transaction(*store, req.ref);
                if index >= 0 store_remove_tag(*store, index, store_find_tag(*store, req.arg));
            }
            if !batch_reply(req, ok) && !ok app_toast(.ERROR, tprint("Tag not added: %", api_error_message(req)));

        case .REMOVE_TAG;
            sync.pending_writes -= 1;
            if !ok {
                index := store_find_transaction(*store, req.ref);
                if index >= 0 store_add_tag(*store, index, store_find_tag(*store, req.arg));
            }
            if !batch_reply(req, ok) && !ok app_toast(.ERROR, tprint("Tag not removed: %", api_error_message(req)));

        case .ATTACHMENT;
            if !ok { app_toast(.ERROR, tprint("Attachment unavailable: %", api_error_message(req))); return; }
            doc, parsed := json_parse(req.result.body,, temp);
            url := ifx parsed then json_string(json_at(*doc, "data", "attributes", "fileURL")) else "";
            if url.count && begins_with(url, "https://") {
                platform_open_url(url);
                app_toast(.INFO, "Opened the receipt in your browser (the link expires after a while).");
            } else {
                app_toast(.INFO, "This attachment has no downloadable file.");
            }

        case .WEBHOOKS;
            if !ok {
                sync.webhooks_state = .FAILED;
                set_string(*sync.webhooks_error, api_error_message(req));
                return;
            }
            doc, parsed := json_parse(req.result.body,, temp);
            if !parsed { sync.webhooks_state = .FAILED; return; }
            if !req.arg.count {
                for * sync.webhooks free_webhook(it);
                sync.webhooks.count = 0;
            }
            for * json_array(json_get(*doc, "data")) {
                w, secret := parse_webhook(it);
                free(secret);
                array_add(*sync.webhooks, w);
            }
            next := json_string(json_at(*doc, "links", "next"));
            if next.count api_submit(.WEBHOOKS, "GET", next, generation = req.generation, arg = "more");
            else sync.webhooks_state = .LOADED;

        case .WEBHOOK_CREATE;
            sync.webhook_busy -= 1;
            if !ok { app_toast(.ERROR, tprint("Webhook not created: %", api_error_message(req))); return; }
            doc, parsed := json_parse(req.result.body,, temp);
            if !parsed return;
            w, secret := parse_webhook(json_get(*doc, "data"));
            array_add(*sync.webhooks, w);
            free(sync.new_secret);
            sync.new_secret = secret;
            set_string(*sync.new_secret_for, w.id);
            app_on_webhook_created(w.id);
            app_toast(.SUCCESS, "Webhook created. Copy its secret key now: Up won't show it again.");

        case .WEBHOOK_DELETE;
            sync.webhook_busy -= 1;
            if !ok { app_toast(.ERROR, tprint("Webhook not deleted: %", api_error_message(req))); return; }
            for sync.webhooks {
                if it.id != req.ref continue;
                free_webhook(*sync.webhooks[it_index]);
                array_ordered_remove_by_index(*sync.webhooks, it_index);
                break;
            }
            if sync.logs_for == req.ref {
                for * sync.logs free_webhook_log(it);
                sync.logs.count = 0;
                set_string(*sync.logs_for, "");
            }
            app_toast(.SUCCESS, "Webhook deleted.");

        case .WEBHOOK_PING;
            sync.webhook_busy -= 1;
            if !ok { app_toast(.ERROR, tprint("Ping failed: %", api_error_message(req))); return; }
            app_toast(.SUCCESS, "PING event sent. Its delivery appears in the log shortly.");
            if sync.logs_for == req.ref sync_load_logs(req.ref);

        case .WEBHOOK_LOGS;
            if req.ref != sync.logs_for return;
            if !ok { sync.logs_state = .FAILED; return; }
            doc, parsed := json_parse(req.result.body,, temp);
            if !parsed { sync.logs_state = .FAILED; return; }
            for * json_array(json_get(*doc, "data")) array_add(*sync.logs, parse_webhook_log(it));
            set_string(*sync.logs_next, json_string(json_at(*doc, "links", "next")));
            sync.logs_state = .LOADED;

        case .TRANSACTION;
    }
}

maybe_start_transactions :: () {
    if sync.accounts_done && sync.categories_done && sync.pages == 0 && sync.phase == .LOADING begin_transactions();
}

refresh_part_done :: () {
    sync.refresh_waiting -= 1;
    if sync.refresh_waiting > 0 return;
    sync.refreshing = false;
    clear_edits();
    finish_sync();
    kind := sync.refresh_kind;
    if kind == .CATCH_UP sync.from_saved = false;
    if kind == .FULL sync.last_full_check_utc = sync.last_sync_utc;
    if sync.refresh_new > 0 {
        app_toast(.INFO, tprint("% new transaction%", sync.refresh_new, ifx sync.refresh_new == 1 then "" else "s"));
    } else if sync.refresh_manual {
        app_toast(.SUCCESS, ifx kind == .FULL then "Checked every transaction: everything matches Up." else "Up to date.");
    }
    continue_after_refresh();
}

refresh_failed :: (req: *Api_Request) {
    sync.refreshing = false;
    clear_edits();
    for * sync.refresh_batch free_transaction(it);
    sync.refresh_batch.count = 0;
    // A catch-up that couldn't finish is tried again soon, whatever the
    // automatic refresh setting.
    if sync.refresh_kind == .CATCH_UP && transient(req) sync.catch_up_at = ui.time + 30;
    message := api_error_message(req);
    set_string(*sync.error, tprint("Refresh failed: %", message));
    sync.error_status = req.result.status;
    if req.result.status == 401 sync.auth_failed = true;
    // Try again on the next automatic refresh, or sooner when it was transient.
    if transient(req) sync.next_auto = ui.time + 30;
    if sync.refresh_manual app_toast(.ERROR, tprint("Refresh failed: %", message));
}

// The open batch, counting one more write in it (0 when none is open).
join_batch :: () -> u32 {
    b := find_batch(sync.batch_open);
    if !b return 0;
    b.total += 1;
    b.pending += 1;
    return b.id;
}

find_batch :: (id: u32) -> *Write_Batch, int {
    if !id return null, -1;
    for * sync.batches if it.id == id return it, it_index;
    return null, -1;
}

// Counts a write's reply against its batch; false when it has none.
batch_reply :: (req: *Api_Request, ok: bool) -> bool {
    if !req.batch return false;
    b, index := find_batch(req.batch);
    if !b return true;
    b.pending -= 1;
    if !ok {
        b.failed += 1;
        if !b.error.count b.error = copy_string(api_error_message(req));
    }
    finish_batch(index);
    return true;
}

// Once every write is submitted and answered: the one toast.
finish_batch :: (index: int) {
    b := *sync.batches[index];
    if !b.closed || b.pending > 0 return;
    if b.failed app_toast(.ERROR, tprint("%: % of % failed. %", b.failure, b.failed, b.total, b.error));
    else if b.done.count app_toast(.SUCCESS, b.done);
    free(b.done); free(b.failure); free(b.error);
    array_ordered_remove_by_index(*sync.batches, index);
}
