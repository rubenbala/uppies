// The local store file: everything synced from Up, saved between runs so the
// app opens instantly and only downloads what changed.
//
// One file, %APPDATA%/Uppies/store.uppies, written in one step (a temporary
// file renamed over the old one) so it is always either the previous save or
// the new one.
//
//   offset  size  field
//   0       8     magic "UPPIESDB"
//   8       4     file format version (FILE_VERSION)
//   12      4     wrapped key size, K
//   16      8     payload size, N
//   24      12    AES-GCM nonce
//   36      K     wrapped key: the payload key, encrypted with DPAPI
//   36+K    N     payload, encrypted with AES-256-GCM
//   36+K+N  16    GCM authentication tag
//
// Every save draws a new random 256-bit key and nonce. The key is wrapped by
// DPAPI with the Up access token as extra entropy, so the file opens only
// for this Windows user *and* with the same token. The header (bytes 0 to
// 36+K) is authenticated along with the payload: a file that was altered,
// truncated or half-written fails to open and is simply downloaded again.
//
// The payload is a sequence of little-endian records. Integers are LEB128
// varints (signed ones zigzag-encoded); strings are a varint length and
// UTF-8 bytes. Accounts, categories and tags are written in store order, so
// transactions refer to them by index, exactly as the store does.
//
//   meta          PAYLOAD_VERSION, saved, last sync, last full check (UTC
//                 seconds), history depth, history complete, oldest loaded
//   accounts      count, then id, name, currency, type, ownership, balance, created
//   categories    count, then id, name, parent id
//   tags          count, then label
//   transactions  count, then 12 strings, 5 amounts, created, settled,
//                 account, transfer account, category, parent category,
//                 tags, status, card method, flags
//   end           PAYLOAD_END

FILE_MAGIC      :: "UPPIESDB";
FILE_VERSION    :: 1;
PAYLOAD_VERSION :: 1;
PAYLOAD_END     :: 0x21444E45;   // "END!"
HEADER_FIXED    :: 36;

Store_File_Meta :: struct {
    saved_utc:           s64;
    last_sync_utc:       s64;
    last_full_check_utc: s64;
    history:             u8;     // History_Depth the data was loaded with.
    history_complete:    bool;
    oldest_loaded_utc:   s64;
}

Store_File_Status :: enum u8 {
    OK;
    MISSING;     // No file.
    LOCKED;      // Can't be decrypted here: another Windows user, or another token.
    CORRUPT;     // Altered, truncated, or not ours.
    OUTDATED;    // Written by an incompatible version of the app.
}

store_file_path :: () -> string {
    if store_path_override.count return store_path_override;
    return tprint("%/store.uppies", platform_app_data_dir());
}

// Serializes the store (on the calling thread: fast), then encrypts and
// writes it on the writer thread. A newer save replaces one still waiting.
store_file_save :: (s: *Store, meta: Store_File_Meta, secret: string) {
    payload := serialize_store(s, meta);
    writer_init();
    lock(*writer.mutex);
    if writer.job_payload.count wipe_and_free(*writer.job_payload);
    free(writer.job_secret);
    writer.job_payload = payload;
    writer.job_secret = copy_string(secret);
    writer.job_generation = writer.generation;
    writer.queued = true;
    unlock(*writer.mutex);
    signal(*writer.semaphore);
}

// Reads the file into an empty store. Anything but OK leaves the store empty.
store_file_load :: (s: *Store, secret: string) -> Store_File_Meta, Store_File_Status {
    meta: Store_File_Meta;
    path := store_file_path();
    if !file_exists(path) return meta, .MISSING;
    data, read_ok := read_entire_file(path);
    if !read_ok return meta, .CORRUPT;
    defer free(data);
    file: [] u8;
    file.data, file.count = data.data, data.count;

    if file.count < HEADER_FIXED + AES_TAG_SIZE || slice(data, 0, 8) != FILE_MAGIC return meta, .CORRUPT;
    version      := read_u32(file, 8);
    key_size     := cast(s64) read_u32(file, 12);
    payload_size := cast(s64) read_u64(file, 16);
    if version != FILE_VERSION return meta, .OUTDATED;
    if key_size > 4096 || payload_size < 0 || HEADER_FIXED + key_size + payload_size + AES_TAG_SIZE != file.count return meta, .CORRUPT;

    header  := array_view(file, 0, HEADER_FIXED + key_size);
    nonce   := array_view(file, 24, AES_NONCE_SIZE);
    wrapped := array_view(file, HEADER_FIXED, key_size);
    cipher  := array_view(file, HEADER_FIXED + key_size, payload_size);
    tag: [AES_TAG_SIZE] u8;
    memcpy(tag.data, file.data + file.count - AES_TAG_SIZE, AES_TAG_SIZE);

    key_text, unwrapped := platform_unprotect(to_string(wrapped.data, wrapped.count), key_entropy(secret));
    if !unwrapped return meta, .LOCKED;
    key: [] u8;
    key.data, key.count = key_text.data, key_text.count;
    defer wipe_and_free(*key);
    if key.count != AES_KEY_SIZE return meta, .CORRUPT;

    plain, decrypted := platform_aes_gcm_decrypt(key, nonce, header, cipher, tag);
    if !decrypted return meta, .CORRUPT;
    defer wipe_and_free(*plain);

    meta_out, status := deserialize_store(s, plain);
    if status != .OK store_reset(s);
    return meta_out, status;
}

// Deletes the file, and cancels any save not yet written so it can't
// reappear afterwards.
store_file_delete :: () {
    writer_init();
    lock(*writer.mutex);
    writer.generation += 1;
    if writer.job_payload.count wipe_and_free(*writer.job_payload);
    writer.queued = false;
    path := store_file_path();
    if file_exists(path) file_delete(path);
    tmp := tprint("%.tmp", path);
    if file_exists(tmp) file_delete(tmp);
    writer.file_size = 0;
    writer.saved_utc = 0;
    unlock(*writer.mutex);
}

// Size of the file on disk and when it was last written (0 if none yet).
store_file_info :: () -> size: s64, saved_utc: s64, failed: bool {
    writer_init();
    lock(*writer.mutex);
    size, saved, failed := writer.file_size, writer.saved_utc, writer.last_failed;
    unlock(*writer.mutex);
    if !size && !saved {
        // Nothing written this session: look at what's there.
        f, ok := file_open(store_file_path());
        if ok {
            size = file_length(f);
            file_close(*f);
        }
    }
    return size, saved, failed;
}

// Blocks until any queued save has been written (at exit).
store_file_flush :: () {
    if !writer.started return;
    start := seconds_since_init();
    while seconds_since_init() - start < 10 {
        lock(*writer.mutex);
        idle := !writer.queued && !writer.busy;
        unlock(*writer.mutex);
        if idle return;
        sleep_milliseconds(5);
    }
}

// Round trip without touching disk, for the self-test: serialize, encrypt,
// decrypt, parse. Returns the decoded store's status.
store_file_roundtrip_test :: (s: *Store, out: *Store, meta: Store_File_Meta, secret: string, tamper := false, wrong_secret := "") -> Store_File_Status {
    payload := serialize_store(s, meta);
    defer wipe_and_free(*payload);
    file, ok := encrypt_file(payload, secret);
    if !ok return .CORRUPT;
    defer array_free(file);
    if tamper file[file.count / 2] ^= 0x40;
    path := tprint("%/selftest.uppies", platform_app_data_dir());
    write_entire_file(path, file.data, file.count);
    saved_path := store_path_override;
    store_path_override = path;
    defer store_path_override = saved_path;
    _, status := store_file_load(out, ifx wrong_secret.count then wrong_secret else secret);
    file_delete(path);
    return status;
}

#scope_file

store_path_override: string;   // Self-test only.

key_entropy :: (secret: string) -> string {
    return tprint("uppies-store-v1:%", secret);
}

//
// The writer thread: encryption, DPAPI and the disk (including the flush,
// which can take tens of milliseconds) never hold up a frame.
//

Writer :: struct {
    started:   bool;
    thread:    Thread;
    mutex:     Mutex;
    semaphore: Semaphore;

    queued:         bool;
    busy:           bool;
    job_payload:    [] u8;
    job_secret:     string;
    job_generation: u32;
    generation:     u32;   // Bumped by delete: older jobs are dropped.

    file_size:   s64;
    saved_utc:   s64;
    last_failed: bool;
}

writer: Writer;

writer_init :: () {
    if writer.started return;
    writer.started = true;
    init(*writer.mutex);
    init(*writer.semaphore);
    thread_init(*writer.thread, writer_proc);
    thread_start(*writer.thread);
}

writer_proc :: (thread: *Thread) -> s64 {
    while true {
        wait_for(*writer.semaphore);
        lock(*writer.mutex);
        if !writer.queued { unlock(*writer.mutex); continue; }
        payload, secret, generation := writer.job_payload, writer.job_secret, writer.job_generation;
        writer.job_payload = .[];
        writer.job_secret = "";
        writer.queued = false;
        writer.busy = true;
        unlock(*writer.mutex);

        file, ok := encrypt_file(payload, secret);
        wipe_and_free(*payload);
        free(secret);
        path := store_file_path();
        written := false;
        if ok {
            // Rename under the lock so a delete can't be overtaken by an older save.
            lock(*writer.mutex);
            if generation == writer.generation {
                written = platform_write_file_atomic(path, file);
                if written {
                    writer.file_size = file.count;
                    writer.saved_utc = platform_local_time().utc_seconds;
                }
            }
            unlock(*writer.mutex);
            array_free(file);
        }
        lock(*writer.mutex);
        writer.busy = false;
        writer.last_failed = !written && generation == writer.generation;
        unlock(*writer.mutex);
        platform_wake();
        reset_temporary_storage();
    }
    return 0;
}

encrypt_file :: (payload: [] u8, secret: string) -> [] u8, bool {
    key: [AES_KEY_SIZE] u8;
    nonce: [AES_NONCE_SIZE] u8;
    defer memset(key.data, 0, key.count);
    if !platform_random_bytes(key) || !platform_random_bytes(nonce) return .[], false;
    wrapped, wrap_ok := platform_protect(to_string(key.data, key.count), key_entropy(secret));
    if !wrap_ok return .[], false;
    defer free(wrapped);

    header_size := HEADER_FIXED + wrapped.count;
    file := NewArray(header_size + payload.count + AES_TAG_SIZE, u8, initialized = false);
    memcpy(file.data, FILE_MAGIC.data, 8);
    write_u32(file, 8, FILE_VERSION);
    write_u32(file, 12, cast(u32) wrapped.count);
    write_u64(file, 16, cast(u64) payload.count);
    memcpy(file.data + 24, nonce.data, AES_NONCE_SIZE);
    memcpy(file.data + HEADER_FIXED, wrapped.data, wrapped.count);

    cipher, tag, ok := platform_aes_gcm_encrypt(key, nonce, array_view(file, 0, header_size), payload);
    if !ok { array_free(file); return .[], false; }
    memcpy(file.data + header_size, cipher.data, cipher.count);
    memcpy(file.data + header_size + payload.count, tag.data, AES_TAG_SIZE);
    array_free(cipher);
    return file, true;
}

// The plaintext is financial data: zero it before handing memory back.
wipe_and_free :: (bytes: *[] u8) {
    if bytes.data memset(bytes.data, 0, bytes.count);
    array_free(bytes.*);
    bytes.* = .[];
}

read_u32 :: (b: [] u8, at: s64) -> u32 { v: u32; memcpy(*v, b.data + at, 4); return v; }
read_u64 :: (b: [] u8, at: s64) -> u64 { v: u64; memcpy(*v, b.data + at, 8); return v; }
write_u32 :: (b: [] u8, at: s64, v: u32) { memcpy(b.data + at, *v, 4); }
write_u64 :: (b: [] u8, at: s64, v: u64) { memcpy(b.data + at, *v, 8); }

//
// Payload encoding.
//

Encoder :: struct {
    bytes: [..] u8;
}

put_byte :: inline (e: *Encoder, b: u8) { array_add(*e.bytes, b); }

put_uvar :: (e: *Encoder, value: u64) {
    v := value;
    while v >= 0x80 {
        put_byte(e, cast(u8) ((v & 0x7F) | 0x80));
        v >>= 7;
    }
    put_byte(e, cast(u8) v);
}

put_svar :: inline (e: *Encoder, value: s64) {
    put_uvar(e, cast,no_check(u64) ((value << 1) ^ (value >> 63)));   // Zigzag: small magnitudes stay small.
}

put_string :: (e: *Encoder, s: string) {
    put_uvar(e, cast(u64) s.count);
    if s.count {
        at := e.bytes.count;
        array_resize(*e.bytes, at + s.count, initialize = false);
        memcpy(e.bytes.data + at, s.data, s.count);
    }
}

put_time :: (e: *Encoder, t: Timestamp) {
    put_svar(e, t.utc);
    put_svar(e, t.offset);
}

Decoder :: struct {
    bytes:  [] u8;
    at:     s64;
    failed: bool;
}

get_byte :: inline (d: *Decoder) -> u8 {
    if d.at >= d.bytes.count { d.failed = true; return 0; }
    b := d.bytes[d.at];
    d.at += 1;
    return b;
}

get_uvar :: (d: *Decoder) -> u64 {
    result: u64;
    shift: u64;
    while shift < 64 {
        b := get_byte(d);
        if d.failed return 0;
        result |= (cast(u64) (b & 0x7F)) << shift;
        if !(b & 0x80) return result;
        shift += 7;
    }
    d.failed = true;
    return 0;
}

get_svar :: inline (d: *Decoder) -> s64 {
    u := get_uvar(d);
    magnitude := cast,no_check(s64) (u >> 1);
    sign      := cast,no_check(s64) (u & 1);
    return magnitude ^ -sign;
}

// A view into the payload; the caller copies what it keeps.
get_string :: (d: *Decoder) -> string {
    n := cast,no_check(s64) get_uvar(d);
    if d.failed || n < 0 || n > d.bytes.count - d.at { d.failed = true; return ""; }
    s := string.{n, d.bytes.data + d.at};
    d.at += n;
    return s;
}

get_time :: (d: *Decoder) -> Timestamp {
    t: Timestamp;
    t.utc = get_svar(d);
    t.offset = cast,no_check(s32) get_svar(d);
    return t;
}

// A record count, checked against what's left: every record takes at least a byte.
get_count :: (d: *Decoder) -> s64 {
    n := cast,no_check(s64) get_uvar(d);
    if n < 0 || n > d.bytes.count - d.at { d.failed = true; return 0; }
    return n;
}

// An index into a list of `count` items, or -1.
get_index :: (d: *Decoder, count: s64) -> s32 {
    v := get_svar(d);
    if v < -1 || v >= count { d.failed = true; return -1; }
    return cast(s32) v;
}

TXN_CATEGORIZABLE :: 1 << 0;
TXN_HAS_HOLD      :: 1 << 1;
TXN_HAS_SETTLED   :: 1 << 2;
TXN_HAS_FOREIGN   :: 1 << 3;
TXN_HAS_ROUND_UP  :: 1 << 4;
TXN_HAS_CASHBACK  :: 1 << 5;

serialize_store :: (s: *Store, meta: Store_File_Meta) -> [] u8 {
    e: Encoder;
    array_reserve(*e.bytes, 4096 + s.transactions.count * 160);

    put_uvar(*e, PAYLOAD_VERSION);
    put_svar(*e, meta.saved_utc);
    put_svar(*e, meta.last_sync_utc);
    put_svar(*e, meta.last_full_check_utc);
    put_byte(*e, meta.history);
    put_byte(*e, cast(u8) meta.history_complete);
    put_svar(*e, meta.oldest_loaded_utc);

    put_uvar(*e, cast(u64) s.accounts.count);
    for s.accounts {
        put_string(*e, it.id);
        put_string(*e, it.name);
        put_string(*e, it.currency);
        put_byte(*e, cast(u8) it.type);
        put_byte(*e, cast(u8) it.ownership);
        put_svar(*e, it.balance);
        put_time(*e, it.created);
    }

    put_uvar(*e, cast(u64) s.categories.count);
    for s.categories {
        put_string(*e, it.id);
        put_string(*e, it.name);
        put_string(*e, it.parent_id);
    }

    put_uvar(*e, cast(u64) s.tags.count);
    for s.tags put_string(*e, it.label);

    put_uvar(*e, cast(u64) s.transactions.count);
    for * t: s.transactions {
        put_string(*e, t.id);
        put_string(*e, t.description);
        put_string(*e, t.raw_text);
        put_string(*e, t.message);
        put_string(*e, t.note);
        put_string(*e, t.transaction_type);
        put_string(*e, t.performer);
        put_string(*e, t.card_suffix);
        put_string(*e, t.foreign_currency);
        put_string(*e, t.foreign_value);
        put_string(*e, t.cashback_description);
        put_string(*e, t.attachment_id);
        put_svar(*e, t.amount);
        put_svar(*e, t.hold_amount);
        put_svar(*e, t.round_up);
        put_svar(*e, t.round_up_boost);
        put_svar(*e, t.cashback);
        put_time(*e, t.created);
        put_time(*e, t.settled);
        put_svar(*e, t.account);
        put_svar(*e, t.transfer_account);
        put_svar(*e, t.category);
        put_svar(*e, t.parent_category);
        put_byte(*e, cast(u8) t.tag_count);
        for 0..t.tag_count - 1 put_svar(*e, t.tags[it]);
        put_byte(*e, cast(u8) t.status);
        put_byte(*e, cast(u8) t.card_method);
        flags: u8;
        if t.categorizable flags |= TXN_CATEGORIZABLE;
        if t.has_hold      flags |= TXN_HAS_HOLD;
        if t.has_settled   flags |= TXN_HAS_SETTLED;
        if t.has_foreign   flags |= TXN_HAS_FOREIGN;
        if t.has_round_up  flags |= TXN_HAS_ROUND_UP;
        if t.has_cashback  flags |= TXN_HAS_CASHBACK;
        put_byte(*e, flags);
    }

    end: u32 = PAYLOAD_END;
    for 0..3 put_byte(*e, cast(u8) ((end >> (it * 8)) & 0xFF));

    result: [] u8 = e.bytes;
    return result;
}

deserialize_store :: (s: *Store, plain: [] u8) -> Store_File_Meta, Store_File_Status {
    meta: Store_File_Meta;
    d := Decoder.{bytes = plain};
    if get_uvar(*d) != PAYLOAD_VERSION return meta, .OUTDATED;
    meta.saved_utc           = get_svar(*d);
    meta.last_sync_utc       = get_svar(*d);
    meta.last_full_check_utc = get_svar(*d);
    meta.history             = get_byte(*d);
    meta.history_complete    = get_byte(*d) != 0;
    meta.oldest_loaded_utc   = get_svar(*d);


    accounts: [..] Account;
    accounts.allocator = temp;
    for 1..get_count(*d) {
        a: Account;
        a.id        = copy_string(get_string(*d));
        a.name      = copy_string(get_string(*d));
        a.currency  = copy_string(get_string(*d));
        a.type      = cast(Account_Type) min(get_byte(*d), cast(u8) Account_Type.OTHER);
        a.ownership = cast(Ownership) min(get_byte(*d), cast(u8) Ownership.OTHER);
        a.balance   = get_svar(*d);
        a.created   = get_time(*d);
        array_add(*accounts, a);
        if d.failed break;
    }
    store_merge_accounts(s, accounts);

    categories: [..] Category;
    categories.allocator = temp;
    for 1..get_count(*d) {
        c: Category;
        c.id        = copy_string(get_string(*d));
        c.name      = copy_string(get_string(*d));
        c.parent_id = copy_string(get_string(*d));
        array_add(*categories, c);
        if d.failed break;
    }
    store_merge_categories(s, categories);

    for 1..get_count(*d) {
        store_intern_tag(s, get_string(*d));
        if d.failed break;
    }
    if d.failed || s.categories.count > 32767 || s.tags.count > 32767 return meta, .CORRUPT;

    txns: [..] Transaction;
    txns.allocator = temp;
    n := get_count(*d);
    array_reserve(*txns, n);
    for 1..n {
        t: Transaction;
        t.id                   = get_string(*d);
        t.description          = get_string(*d);
        t.raw_text             = get_string(*d);
        t.message              = get_string(*d);
        t.note                 = get_string(*d);
        t.transaction_type     = get_string(*d);
        t.performer            = get_string(*d);
        t.card_suffix          = get_string(*d);
        t.foreign_currency     = get_string(*d);
        t.foreign_value        = get_string(*d);
        t.cashback_description = get_string(*d);
        t.attachment_id        = get_string(*d);
        t.amount         = get_svar(*d);
        t.hold_amount    = get_svar(*d);
        t.round_up       = get_svar(*d);
        t.round_up_boost = get_svar(*d);
        t.cashback       = get_svar(*d);
        t.created = get_time(*d);
        t.settled = get_time(*d);
        t.account          = get_index(*d, s.accounts.count);
        t.transfer_account = get_index(*d, s.accounts.count);
        t.category         = cast(s16) get_index(*d, s.categories.count);
        t.parent_category  = cast(s16) get_index(*d, s.categories.count);
        tag_count := cast(s32) get_byte(*d);
        if tag_count > MAX_TAGS { d.failed = true; break; }
        for 0..tag_count - 1 {
            tag := get_index(*d, s.tags.count);
            if tag >= 0 { t.tags[t.tag_count] = cast(s16) tag; t.tag_count += 1; }
        }
        t.status      = cast(Txn_Status) min(get_byte(*d), cast(u8) Txn_Status.HELD);
        t.card_method = cast(Card_Method) min(get_byte(*d), cast(u8) Card_Method.CONTACTLESS);
        flags := get_byte(*d);
        if d.failed break;
        t.categorizable = (flags & TXN_CATEGORIZABLE) != 0;
        t.has_hold      = (flags & TXN_HAS_HOLD) != 0;
        t.has_settled   = (flags & TXN_HAS_SETTLED) != 0;
        t.has_foreign   = (flags & TXN_HAS_FOREIGN) != 0;
        t.has_round_up  = (flags & TXN_HAS_ROUND_UP) != 0;
        t.has_cashback  = (flags & TXN_HAS_CASHBACK) != 0;
        t.day   = cast(s32) ts_day(t.created);
        t.month = month_key_from_day(t.day);
        pack_transaction_strings(*t);   // Copies the strings out of the payload.
        array_add(*txns, t);
    }
    end: u32;
    for 0..3 end |= (cast(u32) get_byte(*d)) << (it * 8);
    if d.failed || end != PAYLOAD_END || d.at != d.bytes.count {
        for * txns free_transaction(it);
        return meta, .CORRUPT;
    }
    store_merge_transactions(s, txns, -1000);   // Not "new": no highlight.
    return meta, .OK;
}
